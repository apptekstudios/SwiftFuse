import Fuse

let items = (0 ..< 100_000).map { "Item number \($0)" }
let fuse = Fuse(items)

func demo() async throws {
    // In async code `search` resolves to the async variant: big collections are split across
    // cores, and the call honours task cancellation.
    let results = try await fuse.search("item 4242", limit: 5)
    print(results.map(\.item))

    // Typical UI pattern: cancel the previous search when the query changes.
    let task = Task { try await fuse.search("number 99") }
    task.cancel()
    do {
        _ = try await task.value
    } catch is CancellationError {
        print("cancelled")
    }
}

try await demo()
