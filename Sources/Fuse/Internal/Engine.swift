import Foundation

/// A match of one indexed record, before scoring.
struct RawMatch {
    var recordIndex: Int
    var score: Double
    var indices: [Range<Int>]
    var matchedTerms: [Int]
}

struct RawResult {
    var itemIndex: Int
    var matches: [RawMatch]
    var score: Double = 1
}

/// The compiled form of one `search()` call: everything needed to evaluate an item is immutable
/// and `Sendable`, so a job can be split across tasks.
struct SearchJob: Sendable {
    enum Plan: Sendable {
        /// Plain pattern search over every key.
        case flat(AnySearcher)
        /// Logical query tree.
        indirect case leaf(keyIndex: Int?, searcher: AnySearcher)
        indirect case and([Plan])
        indirect case or([Plan])
    }

    let index: FuseIndex
    let plan: Plan
    let normalizedWeights: [Double]
    let ignoreFieldNorm: Bool
    let requireAllTokens: Bool
    let termCount: Int
    let hasKeys: Bool

    init?(pattern: String, index: FuseIndex, options: FuseOptions, weights: [Double]) {
        guard !TextStats.isBlank(pattern) else { return nil }
        let searcher = AnySearcher.make(pattern: pattern, options: options, index: index)
        self.init(plan: .flat(searcher), index: index, options: options, weights: weights, termCount: searcher.termCount)
    }

    init(query: FuseQuery, index: FuseIndex, options: FuseOptions, weights: [Double]) {
        var termCount = 0
        func compile(_ query: FuseQuery) -> Plan {
            switch query {
            case .pattern(let pattern):
                let searcher = AnySearcher.make(pattern: pattern, options: options, index: index)
                termCount = max(termCount, searcher.termCount)
                return .leaf(keyIndex: nil, searcher: searcher)
            case .key(let name, let pattern):
                guard let keyIndex = index.keyNames.firstIndex(of: name) else {
                    preconditionFailure("FuseQuery refers to unknown key '\(name)'. Known keys: \(index.keyNames)")
                }
                let searcher = AnySearcher.make(pattern: pattern, options: options, index: index)
                termCount = max(termCount, searcher.termCount)
                return .leaf(keyIndex: keyIndex, searcher: searcher)
            case .and(let children):
                return .and(children.map(compile))
            case .or(let children):
                return .or(children.map(compile))
            }
        }
        let plan = compile(query)
        self.init(plan: plan, index: index, options: options, weights: weights, termCount: termCount)
    }

    private init(plan: Plan, index: FuseIndex, options: FuseOptions, weights: [Double], termCount: Int) {
        self.index = index
        self.plan = plan
        self.normalizedWeights = weights
        self.ignoreFieldNorm = options.ignoreFieldNorm
        self.requireAllTokens = options.useTokenSearch && options.tokenMatch == .all
        self.termCount = termCount
        self.hasKeys = !index.keyNames.isEmpty
    }

    // MARK: Evaluation

    /// Evaluates items `range`, appending raw results. Checks for cancellation every 256 items when
    /// `cancellable` is set.
    func run(items range: Range<Int>, cancellable: Bool, into results: inout [RawResult]) throws {
        var scratch = BitapScratch()
        try index.codes.withUnsafeBufferPointer { codes in
            var counter = 0
            for itemIndex in range {
                if cancellable {
                    counter += 1
                    if counter & 0xFF == 0 { try Task.checkCancellation() }
                }
                if let result = evaluate(itemIndex: itemIndex, codes: codes, scratch: &scratch) {
                    results.append(result)
                }
            }
        }
    }

    @inline(__always)
    private func evaluate(itemIndex: Int, codes: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> RawResult? {
        let recordRange = index.itemRanges[itemIndex]
        guard !recordRange.isEmpty else { return nil }
        var matches: [RawMatch]
        switch plan {
        case .flat(let searcher):
            guard let flat = evaluateFlat(searcher, recordRange: recordRange, codes: codes, scratch: &scratch) else { return nil }
            matches = flat
        default:
            matches = []
            guard evaluateLogical(plan, recordRange: recordRange, codes: codes, scratch: &scratch, into: &matches), !matches.isEmpty else { return nil }
        }
        if requireAllTokens, !coversAllTerms(matches) { return nil }
        var result = RawResult(itemIndex: itemIndex, matches: matches)
        result.score = computeScore(result.matches)
        return result
    }

    /// Fuse.js `_searchStringList` / `_searchObjectList` for one item.
    private func evaluateFlat(_ searcher: AnySearcher, recordRange: Range<Int>, codes: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> [RawMatch]? {
        var matches: [RawMatch] = []
        var matchedKeys = 0
        var hasInverse = false
        var currentKey: Int32 = -2
        var currentKeyMatched = false
        for recordIndex in recordRange {
            let record = index.records[recordIndex]
            if record.keyIndex != currentKey {
                if currentKeyMatched { matchedKeys += 1 }
                currentKey = record.keyIndex
                currentKeyMatched = false
            }
            guard let match = match(searcher, record: record, recordIndex: recordIndex, codes: codes, scratch: &scratch, hasInverse: &hasInverse) else { continue }
            currentKeyMatched = true
            matches.append(match)
        }
        if currentKeyMatched { matchedKeys += 1 }
        guard !matches.isEmpty else { return nil }
        if hasKeys, hasInverse, matchedKeys < normalizedWeights.count {
            // Fuse.js: an inverse (`!`) term that matched on some key while another key failed
            // means the item should be excluded.
            return nil
        }
        return matches
    }

    /// Fuse.js `_searchLogical`'s `evaluate` for one item. Returns `false` when the node fails.
    private func evaluateLogical(_ node: Plan, recordRange: Range<Int>, codes: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch, into matches: inout [RawMatch]) -> Bool {
        switch node {
        case .flat(let searcher), .leaf(nil, let searcher):
            var hasInverse = false
            var found = false
            for recordIndex in recordRange {
                if let match = match(searcher, record: index.records[recordIndex], recordIndex: recordIndex, codes: codes, scratch: &scratch, hasInverse: &hasInverse) {
                    matches.append(match)
                    found = true
                }
            }
            return found
        case .leaf(let keyIndex?, let searcher):
            var hasInverse = false
            var found = false
            for recordIndex in recordRange {
                let record = index.records[recordIndex]
                guard Int(record.keyIndex) == keyIndex else { continue }
                if let match = match(searcher, record: record, recordIndex: recordIndex, codes: codes, scratch: &scratch, hasInverse: &hasInverse) {
                    matches.append(match)
                    found = true
                }
            }
            return found
        case .and(let children):
            let start = matches.count
            for child in children {
                if !evaluateLogical(child, recordRange: recordRange, codes: codes, scratch: &scratch, into: &matches) {
                    matches.removeSubrange(start...)
                    return false
                }
            }
            return true
        case .or(let children):
            var any = false
            for child in children where evaluateLogical(child, recordRange: recordRange, codes: codes, scratch: &scratch, into: &matches) {
                any = true
            }
            return any
        }
    }

    @inline(__always)
    private func match(_ searcher: AnySearcher, record: FieldRecord, recordIndex: Int, codes: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch, hasInverse: inout Bool) -> RawMatch? {
        if searcher.cannotMatch(bloom: record.bloom) { return nil }
        let text = UnsafeBufferPointer(rebasing: codes[Int(record.offset) ..< Int(record.offset) + Int(record.length)])
        let outcome = searcher.search(text, scratch: &scratch)
        guard outcome.isMatch else { return nil }
        if outcome.hasInverse { hasInverse = true }
        return RawMatch(recordIndex: recordIndex, score: outcome.score, indices: outcome.indices, matchedTerms: outcome.matchedTerms)
    }

    // MARK: Scoring (Fuse.js `computeScoreSingle`)

    func computeScore(_ matches: [RawMatch]) -> Double {
        var total = 1.0
        for match in matches {
            let record = index.records[match.recordIndex]
            let weight: Double? = record.keyIndex >= 0 ? normalizedWeights[Int(record.keyIndex)] : nil
            let base = (match.score == 0 && weight != nil) ? Double.ulpOfOne : match.score
            let exponent = (weight ?? 1) * (ignoreFieldNorm ? 1 : record.norm)
            total *= pow(base, exponent)
        }
        return total
    }

    private func coversAllTerms(_ matches: [RawMatch]) -> Bool {
        guard termCount > 0 else { return true }
        var covered = Set<Int>()
        for match in matches {
            covered.formUnion(match.matchedTerms)
            if covered.count == termCount { return true }
        }
        return covered.count == termCount
    }

    // MARK: Formatting

    func format<Item>(_ raw: RawResult, items: [Item], includeMatches: Bool) -> FuseResult<Item> {
        var matches: [FuseMatch] = []
        if includeMatches {
            matches.reserveCapacity(raw.matches.count)
            for match in raw.matches where !match.indices.isEmpty {
                let record = index.records[match.recordIndex]
                matches.append(FuseMatch(
                    key: record.keyIndex >= 0 ? index.keyNames[Int(record.keyIndex)] : nil,
                    value: index.originals[match.recordIndex],
                    refIndex: record.refIndex >= 0 ? Int(record.refIndex) : nil,
                    indices: match.indices
                ))
            }
        }
        return FuseResult(item: items[raw.itemIndex], refIndex: raw.itemIndex, score: raw.score, matches: matches)
    }
}

extension AnySearcher {
    var termCount: Int {
        if case .token(let searcher) = self { return searcher.termCount }
        return 0
    }
}

// MARK: - Result ordering

enum ResultOrdering {
    /// Fuse.js default `sortFn` with the stable `idx` tie-break.
    @inline(__always)
    static func precedes(_ a: RawResult, _ b: RawResult) -> Bool {
        a.score != b.score ? a.score < b.score : a.itemIndex < b.itemIndex
    }

    /// Sorts (unless `shouldSort` is off) and truncates to `limit`. Uses a bounded heap when only a
    /// small prefix is needed, mirroring Fuse.js' `MaxHeap` path.
    static func finalize(_ results: inout [RawResult], shouldSort: Bool, limit: Int?) {
        if !shouldSort {
            results.sort { $0.itemIndex < $1.itemIndex }
            if let limit, limit >= 0, results.count > limit { results.removeSubrange(limit...) }
            return
        }
        if let limit, limit >= 0, limit < results.count / 4 {
            var heap = BoundedMaxHeap(limit: limit)
            for result in results { heap.insert(result) }
            results = heap.sorted()
            return
        }
        results.sort(by: precedes)
        if let limit, limit >= 0, results.count > limit { results.removeSubrange(limit...) }
    }
}

/// Keeps the `limit` best results seen so far (Fuse.js `MaxHeap`).
struct BoundedMaxHeap {
    let limit: Int
    private var heap: [RawResult] = []

    init(limit: Int) {
        self.limit = limit
        heap.reserveCapacity(limit)
    }

    mutating func insert(_ item: RawResult) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(item)
            bubbleUp(heap.count - 1)
        } else if ResultOrdering.precedes(item, heap[0]) {
            heap[0] = item
            sinkDown(0)
        }
    }

    func sorted() -> [RawResult] {
        heap.sorted(by: ResultOrdering.precedes)
    }

    private mutating func bubbleUp(_ start: Int) {
        var i = start
        while i > 0 {
            let parent = (i - 1) >> 1
            // The "largest" (worst) result sits at the root.
            guard ResultOrdering.precedes(heap[parent], heap[i]) else { break }
            heap.swapAt(i, parent)
            i = parent
        }
    }

    private mutating func sinkDown(_ start: Int) {
        var i = start
        let count = heap.count
        while true {
            var largest = i
            let left = 2 * i + 1
            let right = left + 1
            if left < count, ResultOrdering.precedes(heap[largest], heap[left]) { largest = left }
            if right < count, ResultOrdering.precedes(heap[largest], heap[right]) { largest = right }
            if largest == i { return }
            heap.swapAt(i, largest)
            i = largest
        }
    }
}
