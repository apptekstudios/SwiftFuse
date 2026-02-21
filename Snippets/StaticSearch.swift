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

// Static search on strings -- no Fuse instance needed
let names = ["John", "Jane", "Bob"]
let stringResults = try await Fuse<String>.search("jon", in: names)
for result in stringResults {
    print("\(result.item) (score: \(result.score))")
}

// Static search on Fuseable objects
let books = [
    Book(title: "The Lord of the Rings", author: "J.R.R. Tolkien"),
    Book(title: "1984", author: "George Orwell"),
]
let bookResults = try await Fuse<Book>.search("tolkien", in: books)
for result in bookResults {
    print("\(result.item.title) by \(result.item.author)")
}
