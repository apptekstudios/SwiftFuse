import Fuse

struct Book: FuseSearchable {
    var title: String
    var author: String
    var tags: [String]

    // Higher weight = more important. Keys can be key paths or closures.
    static let fuseKeys: [FuseKey<Book>] = [
        FuseKey("title", weight: 2, \.title),
        FuseKey("author", \.author),
        FuseKey("tags", weight: 0.5, \.tags),      // every element is indexed separately
    ]
}

let books = [
    Book(title: "Old Man's War", author: "John Scalzi", tags: ["fiction", "sci-fi"]),
    Book(title: "The Lock Artist", author: "Steve Hamilton", tags: ["thriller"]),
    Book(title: "The DaVinci Code", author: "Dan Brown", tags: ["thriller", "code"]),
]

let fuse = Fuse(books)
for result in fuse.search("thriller") {
    print("\(result.item.title) by \(result.item.author) — \(result.score)")
}

// Keys can also be passed explicitly, for types you don't own:
let byAuthor = Fuse(books, keys: [FuseKey("author") { $0.author }])
print(byAuthor.search("brwn").first?.item.title ?? "no match")
