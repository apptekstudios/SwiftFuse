import Foundation

/// The pre-processed, searchable form of a collection.
///
/// A `FuseIndex` holds, for every indexed field value, the normalised character codes, a
/// character-presence summary used to skip hopeless candidates, the field-length norm and the
/// original text. It does **not** hold the items themselves, so it is `Codable` on its own and can
/// be created once (``Fuse/createIndex(_:keys:options:)``), stored, and later handed back to
/// ``Fuse/init(_:keys:index:options:)`` together with the same items — the Fuse.js
/// `createIndex` / `parseIndex` workflow.
///
/// You rarely need to touch this type: ``Fuse`` builds its index lazily on the first search.
public struct FuseIndex: Sendable, Codable {
    /// Names of the keys the index was built with, in key order. Empty for `[String]` collections.
    public let keyNames: [String]
    /// Number of items the index covers.
    public private(set) var itemCount: Int
    /// Number of indexed field values (blank values are not indexed).
    public var recordCount: Int { records.count }

    let normalizer: TextNormalizer
    let fieldNormWeight: Double

    var codes: [UInt32]
    var records: [FieldRecord]
    /// `records` slice for each item (records are grouped by item, in item order).
    var itemRanges: [Range<Int>]
    /// Original text of each record (parallel to `records`).
    var originals: [String]
    /// Corpus statistics for token search, present only when built with `useTokenSearch`.
    var tokenStatistics: TokenStatistics?

    /// Whether this index is compatible with `options` (same normalisation, norm weight and
    /// token-search mode).
    public func isCompatible(with options: FuseOptions) -> Bool {
        normalizer == TextNormalizer(options: options)
            && fieldNormWeight == options.fieldNormWeight
            && (tokenStatistics != nil) == options.useTokenSearch
    }
}

/// One indexed field value.
struct FieldRecord: Sendable, Hashable, Codable {
    var itemIndex: Int32
    /// Position in `keyNames`, or `-1` for a `[String]` collection.
    var keyIndex: Int32
    /// Element index for array-valued keys, or `-1`.
    var refIndex: Int32
    var offset: Int32
    var length: Int32
    var norm: Double
    var bloom: UInt64
}

/// Fuse.js inverted-index statistics for token search.
struct TokenStatistics: Sendable, Codable, Equatable {
    var fieldCount: Int = 0
    /// Document frequency: number of fields each term occurs in.
    var documentFrequency: [String: Int] = [:]
    var docFieldCount: [Int: Int] = [:]
    var docTermFieldHits: [Int: [String: Int]] = [:]

    mutating func addField(terms: [String], docIndex: Int) {
        guard !terms.isEmpty else { return }
        fieldCount += 1
        docFieldCount[docIndex, default: 0] += 1
        var perDoc = docTermFieldHits.removeValue(forKey: docIndex) ?? [:]
        for term in Set(terms) {
            perDoc[term, default: 0] += 1
            documentFrequency[term, default: 0] += 1
        }
        docTermFieldHits[docIndex] = perDoc
    }

    mutating func removeDocument(_ docIndex: Int) {
        guard let fields = docFieldCount.removeValue(forKey: docIndex) else { return }
        fieldCount -= fields
        guard let perDoc = docTermFieldHits.removeValue(forKey: docIndex) else { return }
        for (term, hits) in perDoc {
            let next = (documentFrequency[term] ?? 0) - hits
            if next <= 0 {
                documentFrequency.removeValue(forKey: term)
            } else {
                documentFrequency[term] = next
            }
        }
    }

    /// Removes documents and renumbers the remaining ones (Fuse.js `removeAndShiftInvertedIndex`).
    mutating func removeAndShift(_ removed: [Int]) {
        guard !removed.isEmpty else { return }
        let sorted = Array(Set(removed)).sorted()
        for index in sorted {
            removeDocument(index)
        }
        func shifted(_ old: Int) -> Int {
            old - sorted.lowerBoundCount(lessThan: old)
        }
        docFieldCount = Dictionary(uniqueKeysWithValues: docFieldCount.map { (shifted($0.key), $0.value) })
        docTermFieldHits = Dictionary(uniqueKeysWithValues: docTermFieldHits.map { (shifted($0.key), $0.value) })
    }
}

extension Array where Element == Int {
    /// Number of elements strictly less than `value` (array must be sorted ascending).
    func lowerBoundCount(lessThan value: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) >> 1
            if self[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

// MARK: - Building

/// Builds index records for a slice of items; several builders run in parallel for big
/// collections and their output is concatenated.
struct IndexBuilder<Item: Sendable>: Sendable {
    let keys: [FuseKey<Item>]
    /// Set for `[String]` collections (no keys): extracts the item's text without a dynamic cast.
    let stringValue: (@Sendable (Item) -> String)?
    let normalizer: TextNormalizer
    let fieldNormWeight: Double
    let tokenizer: FuseTokenizer?

    init(keys: [FuseKey<Item>], options: FuseOptions, stringValue: (@Sendable (Item) -> String)? = nil) {
        self.keys = keys
        let fallback: @Sendable (Item) -> String = { ($0 as? String) ?? "" }
        self.stringValue = stringValue ?? (keys.isEmpty ? fallback : nil)
        self.normalizer = TextNormalizer(options: options)
        self.fieldNormWeight = options.fieldNormWeight
        self.tokenizer = options.useTokenSearch ? (options.tokenizer ?? .default) : nil
    }

    struct Shard: Sendable {
        var codes: [UInt32] = []
        var records: [FieldRecord] = []
        var itemRanges: [Range<Int>] = []
        var originals: [String] = []
        var tokenStatistics: TokenStatistics?
    }

    func buildShard(_ items: ArraySlice<Item>, firstItemIndex: Int) -> Shard {
        var shard = Shard()
        shard.codes.reserveCapacity(items.count * 24)
        shard.records.reserveCapacity(items.count * max(1, keys.count))
        shard.itemRanges.reserveCapacity(items.count)
        shard.originals.reserveCapacity(items.count * max(1, keys.count))
        if tokenizer != nil {
            shard.tokenStatistics = TokenStatistics()
        }
        var norm = FieldNorm(weight: fieldNormWeight)
        var cache: [Character: UInt32] = [:]
        var itemIndex = firstItemIndex
        for item in items {
            append(item, itemIndex: itemIndex, to: &shard, norm: &norm, cache: &cache)
            itemIndex += 1
        }
        return shard
    }

    func append(_ item: Item, itemIndex: Int, to shard: inout Shard, norm: inout FieldNorm, cache: inout [Character: UInt32]) {
        let recordStart = shard.records.count
        if let stringValue {
            addRecord(stringValue(item), itemIndex: itemIndex, keyIndex: -1, refIndex: -1, to: &shard, norm: &norm, cache: &cache)
        } else {
            for (keyIndex, key) in keys.enumerated() {
                switch key.value(for: item) {
                case .none:
                    continue
                case .string(let text):
                    addRecord(text, itemIndex: itemIndex, keyIndex: Int32(keyIndex), refIndex: -1, to: &shard, norm: &norm, cache: &cache)
                case .strings(let texts):
                    for (refIndex, text) in texts.enumerated() {
                        addRecord(text, itemIndex: itemIndex, keyIndex: Int32(keyIndex), refIndex: Int32(refIndex), to: &shard, norm: &norm, cache: &cache)
                    }
                }
            }
        }
        shard.itemRanges.append(recordStart ..< shard.records.count)
    }

    private func addRecord(_ text: String, itemIndex: Int, keyIndex: Int32, refIndex: Int32, to shard: inout Shard, norm: inout FieldNorm, cache: inout [Character: UInt32]) {
        let offset = shard.codes.count
        let encoded = normalizer.encode(text, into: &shard.codes, cache: &cache)
        if encoded.isBlank {
            // Fuse.js does not index blank values.
            shard.codes.removeSubrange(offset...)
            return
        }
        shard.records.append(FieldRecord(
            itemIndex: Int32(itemIndex),
            keyIndex: keyIndex,
            refIndex: refIndex,
            offset: Int32(offset),
            length: Int32(encoded.length),
            norm: norm.value(forTokenCount: encoded.tokenCount),
            bloom: encoded.bloom
        ))
        shard.originals.append(text)
        if let tokenizer {
            shard.tokenStatistics?.addField(terms: tokenizer.tokenize(normalizer.normalizeString(text)), docIndex: itemIndex)
        }
    }

    /// Concatenates shards (in order) into an index.
    func assemble(_ shards: [Shard], itemCount: Int) -> FuseIndex {
        var codes: [UInt32] = []
        var records: [FieldRecord] = []
        var itemRanges: [Range<Int>] = []
        var originals: [String] = []
        codes.reserveCapacity(shards.reduce(0) { $0 + $1.codes.count })
        records.reserveCapacity(shards.reduce(0) { $0 + $1.records.count })
        itemRanges.reserveCapacity(itemCount)
        originals.reserveCapacity(records.capacity)
        var statistics: TokenStatistics? = tokenizer == nil ? nil : TokenStatistics()
        for shard in shards {
            let codeBase = Int32(codes.count)
            let recordBase = records.count
            codes.append(contentsOf: shard.codes)
            for var record in shard.records {
                record.offset += codeBase
                records.append(record)
            }
            for range in shard.itemRanges {
                itemRanges.append(range.lowerBound + recordBase ..< range.upperBound + recordBase)
            }
            originals.append(contentsOf: shard.originals)
            if var merged = statistics, let part = shard.tokenStatistics {
                merged.fieldCount += part.fieldCount
                merged.documentFrequency.merge(part.documentFrequency, uniquingKeysWith: +)
                merged.docFieldCount.merge(part.docFieldCount, uniquingKeysWith: +)
                merged.docTermFieldHits.merge(part.docTermFieldHits) { $0.merging($1, uniquingKeysWith: +) }
                statistics = merged
            }
        }
        return FuseIndex(
            keyNames: keys.map(\.name),
            itemCount: itemCount,
            normalizer: normalizer,
            fieldNormWeight: fieldNormWeight,
            codes: codes,
            records: records,
            itemRanges: itemRanges,
            originals: originals,
            tokenStatistics: statistics
        )
    }

    /// Items per shard when building in parallel. Below this the whole build is one pass.
    static var parallelShardSize: Int { 4096 }

    func shardRanges(count: Int, workers: Int) -> [Range<Int>] {
        guard count > Self.parallelShardSize, workers > 1 else { return [0 ..< count] }
        let shardCount = min(workers, (count + Self.parallelShardSize - 1) / Self.parallelShardSize)
        let size = (count + shardCount - 1) / shardCount
        return stride(from: 0, to: count, by: size).map { $0 ..< min($0 + size, count) }
    }

    /// Synchronous build. Large collections are sharded across cores with `concurrentPerform`.
    func build(_ items: [Item]) -> FuseIndex {
        let ranges = shardRanges(count: items.count, workers: ProcessInfo.processInfo.activeProcessorCount)
        if ranges.count == 1 {
            return assemble([buildShard(items[...], firstItemIndex: 0)], itemCount: items.count)
        }
        let shards = Locked([Shard?](repeating: nil, count: ranges.count))
        DispatchQueue.concurrentPerform(iterations: ranges.count) { index in
            let range = ranges[index]
            let shard = buildShard(items[range], firstItemIndex: range.lowerBound)
            shards.withLock { $0[index] = shard }
        }
        return assemble(shards.withLock { $0.map { $0! } }, itemCount: items.count)
    }

    /// Asynchronous build using a task group, so it never blocks the caller's thread for long.
    func build(_ items: [Item]) async -> FuseIndex {
        let ranges = shardRanges(count: items.count, workers: ProcessInfo.processInfo.activeProcessorCount)
        if ranges.count == 1 {
            return assemble([buildShard(items[...], firstItemIndex: 0)], itemCount: items.count)
        }
        let shards = await withTaskGroup(of: (Int, Shard).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    (index, buildShard(items[range], firstItemIndex: range.lowerBound))
                }
            }
            var result = [Shard?](repeating: nil, count: ranges.count)
            for await (index, shard) in group {
                result[index] = shard
            }
            return result.map { $0! }
        }
        return assemble(shards, itemCount: items.count)
    }
}

// MARK: - Incremental updates

extension FuseIndex {
    /// Appends records for `items`, which become items `itemCount ..< itemCount + items.count`.
    mutating func append<Item>(_ items: [Item], builder: IndexBuilder<Item>) {
        guard !items.isEmpty else { return }
        var shard = IndexBuilder<Item>.Shard()
        var norm = FieldNorm(weight: fieldNormWeight)
        var cache: [Character: UInt32] = [:]
        if tokenStatistics != nil {
            shard.tokenStatistics = TokenStatistics()
        }
        var itemIndex = itemCount
        for item in items {
            builder.append(item, itemIndex: itemIndex, to: &shard, norm: &norm, cache: &cache)
            itemIndex += 1
        }
        let codeBase = Int32(codes.count)
        let recordBase = records.count
        codes.append(contentsOf: shard.codes)
        for var record in shard.records {
            record.offset += codeBase
            records.append(record)
        }
        for range in shard.itemRanges {
            itemRanges.append(range.lowerBound + recordBase ..< range.upperBound + recordBase)
        }
        originals.append(contentsOf: shard.originals)
        if var statistics = tokenStatistics, let part = shard.tokenStatistics {
            statistics.fieldCount += part.fieldCount
            statistics.documentFrequency.merge(part.documentFrequency, uniquingKeysWith: +)
            statistics.docFieldCount.merge(part.docFieldCount, uniquingKeysWith: +)
            statistics.docTermFieldHits.merge(part.docTermFieldHits) { $0.merging($1, uniquingKeysWith: +) }
            tokenStatistics = statistics
        }
        itemCount += items.count
    }

    /// Removes the given items and renumbers the rest. Codes of removed records are left in the
    /// arena (compacted on the next full rebuild) so removal stays O(records).
    mutating func remove(itemIndices: [Int]) {
        guard !itemIndices.isEmpty else { return }
        let removed = Set(itemIndices)
        var newRecords: [FieldRecord] = []
        var newOriginals: [String] = []
        var newRanges: [Range<Int>] = []
        newRecords.reserveCapacity(records.count)
        newOriginals.reserveCapacity(originals.count)
        newRanges.reserveCapacity(itemCount - removed.count)
        var shift: Int32 = 0
        for (itemIndex, range) in itemRanges.enumerated() {
            if removed.contains(itemIndex) {
                shift += 1
                continue
            }
            let start = newRecords.count
            for recordIndex in range {
                var record = records[recordIndex]
                record.itemIndex -= shift
                newRecords.append(record)
                newOriginals.append(originals[recordIndex])
            }
            newRanges.append(start ..< newRecords.count)
        }
        records = newRecords
        originals = newOriginals
        itemRanges = newRanges
        itemCount = newRanges.count
        tokenStatistics?.removeAndShift(itemIndices)
    }
}
