import Fuse

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

let books = [
    Book(title: "The Lord of the Rings", author: "J.R.R. Tolkien"),
    Book(title: "1984", author: "George Orwell"),
    Book(title: "Old Man's War", author: "John Scalzi"),
]

let fuse = Fuse(data: books)
let results = try await fuse.search("tolkien")

for result in results {
    print("\(result.item.title) by \(result.item.author) -- score: \(result.score)")
}
