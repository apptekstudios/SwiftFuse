import Fuse

struct Contact: Fuseable {
    var name: String
    var email: String
    var notes: String

    var fuseProperties: [String: FuseProperty] {
        [
            "name": FuseProperty(value: name, weight: 0.6),    // Most important
            "email": FuseProperty(value: email, weight: 0.3),  // Moderate
            "notes": FuseProperty(value: notes, weight: 0.1),  // Least important
        ]
    }
}

let contacts = [
    Contact(name: "Alice Smith", email: "alice@example.com", notes: "Met at conference"),
    Contact(name: "Bob Jones", email: "bob.alice@work.com", notes: "Alice's colleague"),
    Contact(name: "Charlie Brown", email: "charlie@example.com", notes: "Knows Alice"),
]

let fuse = Fuse(data: contacts)
let results = try await fuse.search("alice")

for result in results {
    print("\(result.item.name) -- overall score: \(result.score)")
    for (key, match) in result.results {
        print("  \(key): score \(match.score)")
    }
}
