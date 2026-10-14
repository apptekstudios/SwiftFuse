import Foundation
import Testing
@testable import Fuse

// MARK: - Shared fixtures

struct Book: FuseSearchable, Equatable {
    var title: String
    var author: String
    var tags: [String] = []
    var isbn: String? = nil

    static let fuseKeys: [FuseKey<Book>] = [
        FuseKey("title", weight: 2, \.title),
        FuseKey("author", \.author),
        FuseKey("tags", weight: 0.5, \.tags),
        FuseKey("isbn", \.isbn),
    ]
}

enum Fixtures {
    static let books: [Book] = [
        Book(title: "Old Man's War", author: "John Scalzi", tags: ["fiction", "sci-fi"], isbn: "978-0765348272"),
        Book(title: "The Lock Artist", author: "Steve Hamilton", tags: ["thriller"]),
        Book(title: "HTML5", author: "Remy Sharp", tags: ["web", "html", "programming"]),
        Book(title: "Right Ho Jeeves", author: "P.D. Woodhouse"),
        Book(title: "The Code of the Wooster", author: "P.D. Woodhouse", tags: ["comedy", "jeeves"]),
        Book(title: "Thank You Jeeves", author: "P.D. Woodhouse"),
        Book(title: "The DaVinci Code", author: "Dan Brown", tags: ["thriller", "code"]),
        Book(title: "Angels & Demons", author: "Dan Brown", tags: ["thriller"]),
        Book(title: "The Silmarillion", author: "J.R.R. Tolkien", tags: ["fantasy"]),
        Book(title: "Syrup", author: "Max Barry", tags: ["satire"]),
        Book(title: "The Lost Symbol", author: "Dan Brown", tags: ["thriller", "symbol"]),
        Book(title: "Lamb", author: "Christopher Moore", tags: ["comedy", "religion"]),
        Book(title: "Incompetence", author: "Rob Grant", tags: ["comedy", "sci-fi"]),
        Book(title: "The Grand Design", author: "Stephen Hawking", tags: ["science", "physics"]),
    ]

    static let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson", "Johnny Appleseed", "John Doe", "Jonathan Swift"]

    static let unicode = ["Crème Brûlée", "creme brulee", "Café Noir", "naïve", "Zoë Saldaña", "Łódź", "Ørsted", "Ελληνικά", "Привет мир", "日本語テキスト", "🍎 apple pie", "apple 🥧 pie", "👨‍👩‍👧 family picnic", "e\u{301}clair", "éclair", "line\r\nbreak"]

    static func words(_ count: Int, seed: UInt64 = 7) -> [String] {
        let vocabulary = ["anesthesia", "general", "regional", "spinal", "epidural", "block", "femoral", "nerve", "laparoscopic", "cholecystectomy", "knee", "arthroscopy", "hip", "replacement", "caesarean", "section", "tonsillectomy", "cataract", "dental", "extraction"]
        var rng = SplitMix64(state: seed)
        return (0 ..< count).map { _ in
            (0 ..< Int.random(in: 1 ... 4, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Result comparison helpers

struct ResultSnapshot: Equatable, CustomStringConvertible {
    var refIndex: Int
    var score: Double
    var matches: [FuseMatch]

    init<Item>(_ result: FuseResult<Item>) {
        refIndex = result.refIndex
        score = result.score
        matches = result.matches
    }

    static func == (lhs: ResultSnapshot, rhs: ResultSnapshot) -> Bool {
        lhs.refIndex == rhs.refIndex && lhs.matches == rhs.matches && approximatelyEqual(lhs.score, rhs.score)
    }

    var description: String {
        "(\(refIndex), \(score), \(matches.map { "\($0.key ?? "-")[\($0.refIndex.map(String.init) ?? "")]=\($0.indices)" }))"
    }
}

func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance * max(1, abs(a), abs(b))
}

func snapshots<Item>(_ results: [FuseResult<Item>]) -> [ResultSnapshot] {
    results.map(ResultSnapshot.init)
}

/// Forces the synchronous `search` overload from inside `async` code (where Swift prefers the
/// async overload).
func syncSearch<Item>(_ fuse: Fuse<Item>, _ pattern: String, limit: Int? = nil) -> [FuseResult<Item>] {
    fuse.search(pattern, limit: limit)
}
