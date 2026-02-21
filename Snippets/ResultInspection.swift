import Fuse

// snippet.hide
struct Book: Fuseable {
    var title: String
    var author: String

    var fuseProperties: [String: FuseProperty] {
        [
            "title": FuseProperty(value: title, weight: 0.3),
            "author": FuseProperty(value: author, weight: 0.7),
        ]
    }
}
// snippet.show

let books = [
    Book(title: "Old Man's War", author: "John Scalzi"),
    Book(title: "The Lord of the Rings", author: "J.R.R. Tolkien"),
]

let fuse = Fuse(data: books)
let results = try await fuse.search("old man")

for result in results {
    print("Item: \(result.item.title)")    // The matched object
    print("Index: \(result.index)")         // Original index in source array
    print("Score: \(result.score)")         // 0.0 = perfect, higher = worse

    for (key, match) in result.results {
        print("  Property '\(key)': score \(match.score)")
        let text = key == "title" ? result.item.title : result.item.author
        for range in match.ranges {
            print("    Matched: \"\(text[range])\"")
        }
    }
}

// Limit number of results
let topResult = try await fuse.search("old", maxResults: 1)
print("\nTop result: \(topResult.first?.item.title ?? "none")")
