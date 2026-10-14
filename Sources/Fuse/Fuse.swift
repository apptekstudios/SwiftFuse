import Foundation

/// Fuzzy search over a collection, with the semantics and scoring of
/// [Fuse.js](https://www.fusejs.io).
///
/// ```swift
/// let fuse = Fuse(["Old Man's War", "The Lock Artist", "HTML5"])
/// let hits = fuse.search("old")            // [FuseResult<String>]
/// hits.first?.item                           // "Old Man's War"
/// ```
///
/// Creating a `Fuse` is O(1): the index is built on the first search (or in the background /
/// immediately, see ``IndexingStrategy``) and then reused. Searches are available synchronously
/// (single-threaded, no suspension) and asynchronously (large collections are split across cores,
/// and the call respects task cancellation).
///
/// `Fuse` is a thread-safe reference type: items can be added and removed after creation and the
/// index is updated incrementally.
public final class Fuse<Item: Sendable>: @unchecked Sendable {
    /// When the index is built.
    public enum IndexingStrategy: Sendable {
        /// Build on the first search. `init` does no work. **Default.**
        case lazy
        /// Start building on a detached background task as soon as the instance is created. The
        /// first search waits for that task instead of building itself.
        case background
        /// Build synchronously inside `init`.
        case immediate
    }

    /// The options this instance was created with.
    public let options: FuseOptions
    /// The keys this instance searches. Empty for `[String]` collections.
    public let keys: [FuseKey<Item>]

    private let builder: IndexBuilder<Item>
    private let normalizedWeights: [Double]
    private let state: Locked<State>

    private struct State {
        var items: [Item]
        var index: IndexState
        /// Bumped on every mutation so a stale build is never stored.
        var version: UInt64 = 0
    }

    private enum IndexState {
        case pending
        case building(Task<FuseIndex, Never>, version: UInt64)
        case ready(FuseIndex)
    }

    // MARK: - Creating

    /// Creates a search over `items`, extracting text with `keys`.
    public convenience init(_ items: [Item], keys: [FuseKey<Item>], options: FuseOptions = .default, indexing: IndexingStrategy = .lazy) {
        self.init(items, keys: keys, options: options, indexing: indexing, stringValue: nil)
    }

    init(_ items: [Item], keys: [FuseKey<Item>], options: FuseOptions, indexing: IndexingStrategy, stringValue: (@Sendable (Item) -> String)?) {
        self.options = options
        self.keys = keys
        self.builder = IndexBuilder(keys: keys, options: options, stringValue: stringValue)
        let totalWeight = keys.reduce(0) { $0 + $1.weight }
        self.normalizedWeights = keys.map { $0.weight / totalWeight }
        self.state = Locked(State(items: items, index: .pending))
        startIndexing(indexing)
    }

    /// Creates a search over `items` using a prebuilt index (see ``createIndex(_:keys:options:)``).
    ///
    /// - Precondition: `index` was built for exactly these items with the same key names and
    ///   compatible options.
    public init(_ items: [Item], keys: [FuseKey<Item>], index: FuseIndex, options: FuseOptions = .default) {
        precondition(index.itemCount == items.count, "FuseIndex covers \(index.itemCount) items but \(items.count) were supplied")
        precondition(index.keyNames == keys.map(\.name), "FuseIndex key names \(index.keyNames) do not match supplied keys \(keys.map(\.name))")
        precondition(index.isCompatible(with: options), "FuseIndex was built with different normalisation options")
        self.options = options
        self.keys = keys
        self.builder = IndexBuilder(keys: keys, options: options)
        let totalWeight = keys.reduce(0) { $0 + $1.weight }
        self.normalizedWeights = keys.map { $0.weight / totalWeight }
        self.state = Locked(State(items: items, index: .ready(index)))
    }

    private func startIndexing(_ strategy: IndexingStrategy) {
        switch strategy {
        case .lazy:
            break
        case .immediate:
            let items = state.withLock { $0.items }
            let index = builder.build(items)
            state.withLock { $0.index = .ready(index) }
        case .background:
            let items = state.withLock { $0.items }
            let builder = self.builder
            let task = Task.detached(priority: .utility) { await builder.build(items) }
            state.withLock { $0.index = .building(task, version: 0) }
        }
    }

    // MARK: - Collection

    /// The current items, in index order.
    public var items: [Item] {
        state.withLock { $0.items }
    }

    /// Number of items.
    public var count: Int {
        state.withLock { $0.items.count }
    }

    /// Replaces the whole collection. The index is rebuilt lazily.
    public func setItems(_ items: [Item]) {
        state.withLock {
            $0.items = items
            $0.index = .pending
            $0.version &+= 1
        }
    }

    /// Appends an item. If the index is already built it is extended in place.
    public func add(_ item: Item) {
        add(contentsOf: [item])
    }

    /// Appends items. If the index is already built it is extended in place.
    public func add(contentsOf newItems: [Item]) {
        guard !newItems.isEmpty else { return }
        let builder = self.builder
        state.withLock { state in
            state.items.append(contentsOf: newItems)
            state.version &+= 1
            if case .ready(var index) = state.index {
                index.append(newItems, builder: builder)
                state.index = .ready(index)
            } else {
                state.index = .pending
            }
        }
    }

    /// Removes and returns every item for which `shouldRemove` returns `true`.
    @discardableResult
    public func remove(where shouldRemove: (_ item: Item, _ index: Int) -> Bool) -> [Item] {
        state.withLock { state in
            var removed: [Item] = []
            var removedIndices: [Int] = []
            for (index, item) in state.items.enumerated() where shouldRemove(item, index) {
                removed.append(item)
                removedIndices.append(index)
            }
            guard !removedIndices.isEmpty else { return [] }
            let removedSet = Set(removedIndices)
            state.items = state.items.enumerated().compactMap { removedSet.contains($0.offset) ? nil : $0.element }
            state.version &+= 1
            if case .ready(var index) = state.index {
                index.remove(itemIndices: removedIndices)
                state.index = .ready(index)
            } else {
                state.index = .pending
            }
            return removed
        }
    }

    /// Removes and returns the item at `position`.
    @discardableResult
    public func remove(at position: Int) -> Item {
        state.withLock { state in
            precondition(state.items.indices.contains(position), "Index \(position) out of range")
            let item = state.items.remove(at: position)
            state.version &+= 1
            if case .ready(var index) = state.index {
                index.remove(itemIndices: [position])
                state.index = .ready(index)
            } else {
                state.index = .pending
            }
            return item
        }
    }

    // MARK: - Index

    /// The index for the current items, building it now if needed.
    public var index: FuseIndex {
        resolveIndex().index
    }

    /// Builds the index now (on the calling thread) if it is not ready yet.
    public func prepare() {
        _ = resolveIndex()
    }

    /// Builds the index if it is not ready yet, sharing the work with any build already in flight.
    public func prepare() async {
        _ = await resolveIndexAsync()
    }

    /// Whether the index is built for the current items.
    public var isIndexed: Bool {
        state.withLock {
            if case .ready = $0.index { return true }
            return false
        }
    }

    /// Builds an index for `items` that can be stored and later passed to
    /// ``init(_:keys:index:options:)``.
    public static func createIndex(_ items: [Item], keys: [FuseKey<Item>], options: FuseOptions = .default) -> FuseIndex {
        IndexBuilder(keys: keys, options: options).build(items)
    }

    private func resolveIndex() -> (items: [Item], index: FuseIndex) {
        let (items, indexState, version) = state.withLock { ($0.items, $0.index, $0.version) }
        if case .ready(let index) = indexState {
            return (items, index)
        }
        // Either pending, or an async build is in flight that we cannot wait for synchronously.
        // Building here is always correct; it only duplicates work in the latter (rare) case.
        let index = builder.build(items)
        store(index, version: version)
        return (items, index)
    }

    private func resolveIndexAsync() async -> (items: [Item], index: FuseIndex) {
        let builder = self.builder
        let (items, task, version): ([Item], Task<FuseIndex, Never>?, UInt64) = state.withLock { state in
            switch state.index {
            case .ready(let index):
                return (state.items, Task { index }, state.version)
            case .building(let task, _):
                return (state.items, task, state.version)
            case .pending:
                let items = state.items
                let task = Task.detached { await builder.build(items) }
                state.index = .building(task, version: state.version)
                return (items, task, state.version)
            }
        }
        let index = await task!.value
        store(index, version: version)
        return (items, index)
    }

    private func store(_ index: FuseIndex, version: UInt64) {
        state.withLock { state in
            guard state.version == version else { return }
            if case .ready = state.index { return }
            state.index = .ready(index)
        }
    }

    // MARK: - Searching

    /// Searches synchronously on the calling thread.
    ///
    /// - Parameters:
    ///   - pattern: The text to look for. A blank pattern returns every item, unranked.
    ///   - limit: Maximum number of results.
    public func search(_ pattern: String, limit: Int? = nil) -> [FuseResult<Item>] {
        let (items, index) = resolveIndex()
        guard let job = SearchJob(pattern: pattern, index: index, options: options, weights: normalizedWeights) else {
            return unranked(items, limit: limit)
        }
        var results: [RawResult] = []
        try? job.run(items: 0 ..< index.itemCount, cancellable: false, into: &results)
        return finish(results, job: job, items: items, limit: limit)
    }

    /// Searches with a logical query synchronously on the calling thread.
    public func search(_ query: FuseQuery, limit: Int? = nil) -> [FuseResult<Item>] {
        let (items, index) = resolveIndex()
        let job = SearchJob(query: query, index: index, options: options, weights: normalizedWeights)
        var results: [RawResult] = []
        try? job.run(items: 0 ..< index.itemCount, cancellable: false, into: &results)
        return finish(results, job: job, items: items, limit: limit)
    }

    /// Searches asynchronously. Large collections are evaluated in parallel across cores, and the
    /// search stops early with `CancellationError` if the calling task is cancelled.
    public func search(_ pattern: String, limit: Int? = nil) async throws -> [FuseResult<Item>] {
        let (items, index) = await resolveIndexAsync()
        try Task.checkCancellation()
        guard let job = SearchJob(pattern: pattern, index: index, options: options, weights: normalizedWeights) else {
            return unranked(items, limit: limit)
        }
        return finish(try await run(job), job: job, items: items, limit: limit)
    }

    /// Searches with a logical query asynchronously.
    public func search(_ query: FuseQuery, limit: Int? = nil) async throws -> [FuseResult<Item>] {
        let (items, index) = await resolveIndexAsync()
        try Task.checkCancellation()
        let job = SearchJob(query: query, index: index, options: options, weights: normalizedWeights)
        return finish(try await run(job), job: job, items: items, limit: limit)
    }

    /// Items per task when searching in parallel.
    static var parallelChunkSize: Int { 2048 }

    private func run(_ job: SearchJob) async throws -> [RawResult] {
        let count = job.index.itemCount
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, count / Self.parallelChunkSize)
        if workers <= 1 {
            var results: [RawResult] = []
            try job.run(items: 0 ..< count, cancellable: true, into: &results)
            return results
        }
        let chunk = (count + workers - 1) / workers
        return try await withThrowingTaskGroup(of: [RawResult].self) { group in
            for start in stride(from: 0, to: count, by: chunk) {
                let range = start ..< min(start + chunk, count)
                group.addTask {
                    var results: [RawResult] = []
                    try job.run(items: range, cancellable: true, into: &results)
                    return results
                }
            }
            var all: [RawResult] = []
            for try await part in group {
                all.append(contentsOf: part)
            }
            return all
        }
    }

    private func finish(_ raw: [RawResult], job: SearchJob, items: [Item], limit: Int?) -> [FuseResult<Item>] {
        var results = raw
        ResultOrdering.finalize(&results, shouldSort: options.shouldSort, limit: limit)
        return results.map { job.format($0, items: items, includeMatches: options.includeMatches) }
    }

    private func unranked(_ items: [Item], limit: Int?) -> [FuseResult<Item>] {
        var results = items.enumerated().map { FuseResult(item: $0.element, refIndex: $0.offset, score: 0) }
        if let limit, limit >= 0, results.count > limit { results.removeSubrange(limit...) }
        return results
    }
}

// MARK: - Convenience initialisers

extension Fuse where Item == String {
    /// Creates a search over plain strings.
    public convenience init(_ items: [String], options: FuseOptions = .default, indexing: IndexingStrategy = .lazy) {
        self.init(items, keys: [], options: options, indexing: indexing, stringValue: { $0 })
    }
}

extension Fuse where Item: FuseSearchable {
    /// Creates a search over items that declare their own ``FuseSearchable/fuseKeys``.
    public convenience init(_ items: [Item], options: FuseOptions = .default, indexing: IndexingStrategy = .lazy) {
        self.init(items, keys: Item.fuseKeys, options: options, indexing: indexing)
    }
}

// MARK: - One-off searches

extension Fuse {
    /// Searches `items` once without keeping an index around.
    public static func search(_ pattern: String, in items: [Item], keys: [FuseKey<Item>], options: FuseOptions = .default, limit: Int? = nil) -> [FuseResult<Item>] {
        Fuse(items, keys: keys, options: options).search(pattern, limit: limit)
    }

    /// Searches `items` once without keeping an index around.
    public static func search(_ pattern: String, in items: [Item], keys: [FuseKey<Item>], options: FuseOptions = .default, limit: Int? = nil) async throws -> [FuseResult<Item>] {
        try await Fuse(items, keys: keys, options: options).search(pattern, limit: limit)
    }
}

extension Fuse where Item == String {
    /// Searches strings once without keeping an index around.
    public static func search(_ pattern: String, in items: [String], options: FuseOptions = .default, limit: Int? = nil) -> [FuseResult<String>] {
        Fuse(items, options: options).search(pattern, limit: limit)
    }

    /// Searches strings once without keeping an index around.
    public static func search(_ pattern: String, in items: [String], options: FuseOptions = .default, limit: Int? = nil) async throws -> [FuseResult<String>] {
        try await Fuse(items, options: options).search(pattern, limit: limit)
    }
}

extension Fuse where Item: FuseSearchable {
    /// Searches items once without keeping an index around.
    public static func search(_ pattern: String, in items: [Item], options: FuseOptions = .default, limit: Int? = nil) -> [FuseResult<Item>] {
        Fuse(items, options: options).search(pattern, limit: limit)
    }

    /// Searches items once without keeping an index around.
    public static func search(_ pattern: String, in items: [Item], options: FuseOptions = .default, limit: Int? = nil) async throws -> [FuseResult<Item>] {
        try await Fuse(items, options: options).search(pattern, limit: limit)
    }
}
