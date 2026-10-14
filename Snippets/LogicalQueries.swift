import Fuse

struct Book: FuseSearchable {
    var title: String
    var author: String
    static let title = FuseKey("title", \Book.title)
    static let author = FuseKey("author", \Book.author)
    static let fuseKeys = [title, author]
}

let books = [
    Book(title: "The DaVinci Code", author: "Dan Brown"),
    Book(title: "The Lost Symbol", author: "Dan Brown"),
    Book(title: "The Code of the Wooster", author: "P.D. Woodhouse"),
]
let fuse = Fuse(books)

// Per-key patterns combined with AND / OR — the Fuse.js `$and` / `$or` / `$path` query object.
let results = fuse.search(.and([
    Book.author.matches("brown"),
    .or([Book.title.matches("code"), Book.title.matches("symbol")]),
]))
print(results.map(\.item.title))

// String literals are "match any key" leaves, and `.key(_:pattern:)` works by key name.
print(fuse.search(.and(["wooster", .key("author", pattern: "woodhouse")])).map(\.item.title))
