import Foundation
import Fuse

var items = (0 ..< 50_000).map { "Procedure \($0)" }

// Lazy (default): init is O(1); the first search builds the index.
let lazy = Fuse(items)
print("indexed before first search:", lazy.isIndexed)
_ = lazy.search("procedure 42")
print("indexed after first search:", lazy.isIndexed)

// Background: start indexing on a detached task right away; the first search just waits for it.
let background = Fuse(items, indexing: .background)
func waitForBackgroundIndex() async {
    await background.prepare()
}
await waitForBackgroundIndex()
print("background ready:", background.isIndexed)

// Immediate: build inside init.
let immediate = Fuse(items, indexing: .immediate)
print("immediate ready:", immediate.isIndexed)

// The collection is mutable; the index is updated incrementally.
immediate.add("Procedure 50000")
immediate.remove(at: 0)
let removed = immediate.remove { item, _ in item.hasSuffix("7") }
print("removed \(removed.count) items; \(immediate.count) remain")

// Build an index once, store it, and reuse it later with the same items.
let index = Fuse.createIndex(items, keys: [], options: .default)
let data = try JSONEncoder().encode(index)
let restored = Fuse(items, keys: [], index: try JSONDecoder().decode(FuseIndex.self, from: data))
print("restored:", restored.search("procedure 7").count, "hits")
