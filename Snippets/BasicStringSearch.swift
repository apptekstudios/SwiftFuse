import Fuse

let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

// Create a Fuse instance -- returns immediately, indexes in background
let fuse = Fuse(data: names)

// Search awaits the index if still building
let results = try await fuse.search("john")

for result in results {
    print("\(result.item) (score: \(result.score))")
}

// One-time static search (no instance needed)
let staticResults = try await Fuse<String>.search("john", in: names)
print("Static search found \(staticResults.count) results")
