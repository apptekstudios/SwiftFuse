# SwiftFuse

A lightweight, zero-dependency fuzzy search library for Swift, implementing the [Bitap algorithm](https://en.wikipedia.org/wiki/Bitap_algorithm).

- **Async/await** native with full `Sendable` conformance
- **Non-blocking initialization** -- indexes are built in the background, searches await automatically
- **Zero dependencies** -- pure Swift, no external packages
- **Fast** -- O(1) character access via pre-indexed arrays and character-set pre-filtering
- Supports searching plain strings or structured objects with weighted properties
- Configurable threshold, distance, location, tokenization, and more

## Installation

Add SwiftFuse to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apptekstudios/SwiftFuse.git", from: "1.0.0")
]
```

Then add `"Fuse"` as a dependency of your target:

```swift
.target(name: "YourTarget", dependencies: ["Fuse"])
```

## Quick Start

<!-- From: Snippets/BasicStringSearch.swift -->
```swift
import Fuse

let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

// Create a Fuse instance -- returns immediately, indexes in background
let fuse = Fuse(data: names)

// Search awaits the index if still building
let results = try await fuse.search("john")

for result in results {
    print("\(result.item) (score: \(result.score))")
}
```

For one-off searches, use the static method instead:

```swift
let results = try await Fuse<String>.search("john", in: names)
```

## Searching Structured Objects

Conform your types to the `Fuseable` protocol to search across multiple properties with weighted importance:

<!-- From: Snippets/FuseableSearch.swift -->
```swift
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
```

Lower weights increase a property's influence on the final score. A `weight` of `1.0` (the default) is neutral.

## Static vs Instance Search

**Instance search** builds the index once and reuses it across multiple searches -- use this when searching the same dataset repeatedly:

```swift
let fuse = Fuse(data: books)
let results1 = try await fuse.search("tolkien")
let results2 = try await fuse.search("orwell")   // Index already built
```

**Static search** is a convenience for one-off queries:

<!-- From: Snippets/StaticSearch.swift -->
```swift
// Strings
let results = try await Fuse<String>.search("jon", in: ["John", "Jane", "Bob"])

// Fuseable objects
let results = try await Fuse<Book>.search("tolkien", in: books)
```

Static methods accept the same configuration parameters as the initializer.

## Configuration

All parameters are optional with sensible defaults:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `threshold` | `0.6` | Match sensitivity. `0.0` = perfect match only, `1.0` = match anything |
| `distance` | `100` | How much distance from `location` affects scoring. Higher = more tolerant |
| `location` | `0` | Expected position of the match in the text (0 = start) |
| `isCaseSensitive` | `false` | Whether comparisons are case sensitive |
| `tokenize` | `false` | When `true`, searches individual words and the full string |
| `ignoreLocation` | `false` | When `true`, score is based only on match accuracy, not position |
| `maxPatternLength` | `32` | Maximum search pattern length for the Bitap algorithm |

<!-- From: Snippets/ConfigurationOptions.swift -->
```swift
// Strict matching -- only very close matches
let fuse = Fuse(data: words, threshold: 0.2)

// Case-sensitive
let fuse = Fuse(data: words, isCaseSensitive: true)

// Tokenized search -- matches individual words and full string
let fuse = Fuse(data: words, tokenize: true)

// Location-independent -- score based only on match accuracy
let fuse = Fuse(data: words, ignoreLocation: true)
```

Configuration works with static methods too:

```swift
let results = try await Fuse<String>.search(
    "test",
    in: words,
    threshold: 0.3,
    ignoreLocation: true
)
```

## Inspecting Results

Each `SearchResult` contains:

| Property | Type | Description |
|----------|------|-------------|
| `item` | `T` | The matched item from the source data |
| `index` | `Int` | Original index in the source array |
| `score` | `Double` | Overall match score (`0.0` = perfect, higher = worse) |
| `results` | `[String: ResultItem]` | Per-property match details |

Each `ResultItem` contains a `score` and `ranges` (`[Range<String.Index>]`) that can be used for match highlighting:

<!-- From: Snippets/ResultInspection.swift -->
```swift
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
```

Limit the number of results with `maxResults`:

```swift
let topThree = try await fuse.search("john", maxResults: 3)
```

## Weighted Properties

Property weights control how much each field contributes to the overall score. Lower weight values increase importance:

<!-- From: Snippets/WeightedProperties.swift -->
```swift
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
```

A match on `name` (weight `0.6`) will pull the overall score down (better) more than a match on `notes` (weight `0.1`).

## How It Works

**Bitap algorithm** -- Approximate string matching using bitwise operations. It efficiently finds substrings that are similar to a given pattern, tolerating insertions, deletions, and substitutions.

**Background indexing** -- Creating a `Fuse` instance spawns a background `Task` managed by a private `actor`. The first `search()` call awaits the index if still building; subsequent calls use it immediately.

**Pre-filtering** -- Before running the Bitap algorithm on each candidate, SwiftFuse checks character-set overlap. If fewer than half the pattern's characters exist in the candidate, the expensive search is skipped entirely.

**O(1) character access** -- Strings are pre-converted to `[Character]` arrays during indexing, avoiding costly `String.Index` traversal in the core algorithm loop.

## Concurrency

`Fuse`, `SearchResult`, `ResultItem`, `FuseProperty`, and the `Fuseable` protocol all require `Sendable` conformance. The library is safe to use from any actor or task context. Search methods support structured concurrency via `Task.checkCancellation()`.

## Testable Code Examples

Every code snippet in this README has a corresponding file in the [`Snippets/`](Snippets/) directory. These are compiled and run by Swift Package Manager:

```bash
# Compile library and all snippets
swift build

# Run a specific snippet
swift run BasicStringSearch
```

## License

MIT
