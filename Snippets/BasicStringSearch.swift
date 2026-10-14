import Fuse

let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

// Creating a Fuse is free; the index is built on the first search and reused after that.
let fuse = Fuse(names)

for result in fuse.search("john") {
    print("\(result.item) — score \(result.score)")
}

// One-off search without keeping an instance around:
let topTwo = Fuse.search("jon", in: names, limit: 2)
print(topTwo.map(\.item))
