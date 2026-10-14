# SwiftFuse

[![CI](https://github.com/apptekstudios/SwiftFuse/actions/workflows/ci.yml/badge.svg)](https://github.com/apptekstudios/SwiftFuse/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)

A fast, dependency-free fuzzy-search library for Swift with the semantics, options and scoring of
[Fuse.js](https://www.fusejs.io) — verified against the real Fuse.js, result for result.

```swift
import Fuse

let books = [
    Book(title: "Old Man's War", author: "John Scalzi"),
    Book(title: "The Lock Artist", author: "Steve Hamilton"),
]

let fuse = Fuse(books, keys: [
    FuseKey("title", weight: 2, \.title),
    FuseKey("author", \.author),
])

fuse.search("old man").first?.item.title   // "Old Man's War"
```

- **Fuse.js feature parity** — weighted keys, array values, field-length norm, extended search
  (`=exact`, `'include`, `!inverse`, `^prefix`, `suffix$`, AND/OR), logical queries, token search
  with IDF weighting, match highlighting, mutable collections, exportable indexes. Scores are
  numerically identical to Fuse.js 7.
- **Type-safe** — keys are key paths or closures, never string paths; queries are an enum; results
  carry your item type.
- **Fast** — pre-normalised integer text, a sound character pre-filter, zero allocations in the hot
  loop. 5–6× faster than Fuse.js single-threaded, more with the parallel `async` search.
- **Free to create** — `Fuse(items)` is O(1); the index is built on the first search (or in the
  background) and then reused.
- **Swift 6** — strict concurrency, `Sendable` throughout, sync and `async` APIs, task cancellation.
- **Runs everywhere Swift does** — Apple platforms and Linux; tested with Swift Testing on both.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/apptekstudios/SwiftFuse.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [.product(name: "Fuse", package: "SwiftFuse")]),
]
```

Requires Swift 6.0+ (Xcode 16+). Platforms: iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, Linux.

## Quick start

<!-- From: Snippets/BasicStringSearch.swift -->
```swift
import Fuse

let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

// Creating a Fuse is free; the index is built on the first search and reused after that.
let fuse = Fuse(names)

for result in fuse.search("john") {
    print("\(result.item) — score \(result.score)")
}

// One-off search without keeping an instance around:
let topTwo = Fuse.search("jon", in: names, limit: 2)
```

Each `FuseResult` has the matched `item`, its `refIndex` in the collection, and a `score`
(`0` = perfect, `1` = complete mismatch). Results are sorted best-first.

## Searching objects

Describe the fields to search with `FuseKey`s. A key's `weight` says how much a match in that field
counts (higher = more important; weights are normalised across keys). Values can be a `String`, a
`String?` or a `[String]` — each array element is indexed on its own.

<!-- From: Snippets/SearchingObjects.swift -->
```swift
struct Book: FuseSearchable {
    var title: String
    var author: String
    var tags: [String]

    static let fuseKeys: [FuseKey<Book>] = [
        FuseKey("title", weight: 2, \.title),
        FuseKey("author", \.author),
        FuseKey("tags", weight: 0.5, \.tags),      // every element is indexed separately
    ]
}

let fuse = Fuse(books)                               // keys come from FuseSearchable
let byAuthor = Fuse(books, keys: [FuseKey("author") { $0.author }])   // or pass them explicitly
```

Conforming to `FuseSearchable` is optional; it just lets you write `Fuse(books)`.

## Options

`FuseOptions` mirrors the [Fuse.js options](https://www.fusejs.io/api/options.html) name for name
with the same defaults, so the Fuse.js documentation applies directly.

<!-- From: Snippets/ConfigurationOptions.swift -->
```swift
let strict   = Fuse(words, options: FuseOptions(threshold: 0.2))
let anywhere = Fuse(words, options: FuseOptions(ignoreLocation: true))

var options = FuseOptions()
options.minMatchCharLength = 3
options.includeMatches = true
let configured = Fuse(words, options: options)
```

| Option | Default | Description |
|---|---|---|
| `isCaseSensitive` | `false` | Whether comparisons are case sensitive. |
| `ignoreDiacritics` | `false` | Strip accents from text and pattern before matching (`é` matches `e`). |
| `includeMatches` | `false` | Populate `FuseResult.matches` with the matched values and character ranges. |
| `minMatchCharLength` | `1` | Only matches at least this long are reported. |
| `shouldSort` | `true` | Sort results by score (ties keep collection order). |
| `findAllMatches` | `false` | Keep scanning to the end of the text after a perfect match. |
| `location` | `0` | Where in the text the pattern is expected. |
| `threshold` | `0.6` | When to give up: `0` needs a perfect match, `1` matches anything. |
| `distance` | `100` | How far from `location` a match may be before it scores as a mismatch. |
| `ignoreLocation` | `false` | Score on accuracy only, ignoring position. |
| `ignoreFieldNorm` | `false` | Don't favour shorter fields over longer ones. |
| `fieldNormWeight` | `1` | How strongly field length affects the score (`0` = not at all). |
| `useExtendedSearch` | `false` | Enable the [extended-search](#extended-search) syntax. |
| `useTokenSearch` | `false` | Enable [token search](#token-search). |
| `tokenMatch` | `.any` | Token search: whether `.any` or `.all` query terms must match. |
| `tokenizer` | `nil` | Custom term splitter for token search (default: runs of letters, marks, digits and `_`). |

Scores are always included (they cost nothing), so there is no `includeScore`.

## Extended search

With `useExtendedSearch`, a query is a boolean expression: spaces mean AND, `|` means OR, and each
term can carry an operator. Wrap a term in double quotes to include spaces.

<!-- From: Snippets/ExtendedSearch.swift -->
```swift
let fuse = Fuse(items, options: FuseOptions(useExtendedSearch: true))
fuse.search("^the 'code")        // starts with "the" AND includes "code"
fuse.search("html | jeeves")     // "html" OR "jeeves"
fuse.search("=\"Old Man's War\"") // exact, with a space in the term
```

| Token | Match type | Description |
|---|---|---|
| `jscript` | fuzzy | Items that fuzzy-match `jscript` |
| `=scheme` | exact | Items that are exactly `scheme` |
| `'python` | include | Items that include `python` |
| `!ruby` | inverse exact | Items that do not include `ruby` |
| `^java` | prefix exact | Items that start with `java` |
| `!^earlang` | inverse prefix exact | Items that do not start with `earlang` |
| `.js$` | suffix exact | Items that end with `.js` |
| `!.go$` | inverse suffix exact | Items that do not end with `.go` |

## Logical queries

`FuseQuery` is the type-safe form of the Fuse.js `$and` / `$or` / `$path` query object: combine
per-key patterns with AND and OR to any depth. `FuseKey.matches(_:)` builds a leaf for that key;
a string literal is a leaf that searches every key.

<!-- From: Snippets/LogicalQueries.swift -->
```swift
let results = fuse.search(.and([
    Book.author.matches("brown"),
    .or([Book.title.matches("code"), Book.title.matches("symbol")]),
]))

fuse.search(.and(["wooster", .key("author", pattern: "woodhouse")]))
```

Leaves use whichever matcher the options select (fuzzy, extended or token search).

## Token search

`useTokenSearch` splits the query and every value into terms, fuzzy-matches each term on its own
(position-independent) and combines them with BM25-style inverse-document-frequency weights, so rare
terms count for more than common ones. `tokenMatch: .all` requires every query term to match
somewhere in the item.

```swift
let fuse = Fuse(books, options: FuseOptions(useTokenSearch: true, tokenMatch: .all))
fuse.search("brown thriller")
```

## Highlighting matches

Set `includeMatches` and every result carries `FuseMatch`es: the key, the original field text, the
array element index for array-valued keys, and the matched spans.

<!-- From: Snippets/Highlighting.swift -->
```swift
let fuse = Fuse(items, options: FuseOptions(includeMatches: true))
for match in fuse.search("old war").first?.matches ?? [] {
    for range in match.ranges {          // [Range<String.Index>] into match.value
        print(match.value[range])
    }
}
```

`match.indices` are `Character` offsets and `match.ranges` are the equivalent `String.Index`
ranges. Unlike Fuse.js, offsets are computed per `Character` of the *original* string, so ranges are
always valid — even with emoji, combining marks or letters whose lowercase form changes length.

## Indexing

Creating a `Fuse` does no work. The index is built on the first search and then reused for every
later search; building takes about 3 ms for 10,000 short strings and parallelises across cores for
larger collections. Choose when it happens with `indexing:`:

<!-- From: Snippets/IndexingAndMutation.swift -->
```swift
let lazy = Fuse(items)                               // default: build on first search
let background = Fuse(items, indexing: .background)  // build on a detached task right away
let immediate = Fuse(items, indexing: .immediate)    // build inside init

await background.prepare()      // wait for (or share) an in-flight build
lazy.prepare()                  // build now, synchronously
lazy.isIndexed                  // true
```

### Mutating the collection

`Fuse` is a thread-safe reference type. Items can be added and removed after creation; a built
index is updated in place rather than rebuilt.

```swift
fuse.add(book)
fuse.add(contentsOf: moreBooks)
fuse.remove(at: 3)
let removed = fuse.remove { book, index in book.author == "Dan Brown" }
fuse.setItems(newBooks)         // replaces everything; re-indexes lazily
fuse.items                      // current collection
```

### Exporting an index

`FuseIndex` holds the pre-processed text but not the items, so it is `Codable` on its own. Build it
once, store it, and hand it back together with the same items — the Fuse.js
`createIndex` / `parseIndex` workflow.

```swift
let index = Fuse.createIndex(items, keys: keys)
let data = try JSONEncoder().encode(index)
// later…
let restored = Fuse(items, keys: keys, index: try JSONDecoder().decode(FuseIndex.self, from: data))
```

## Sync and async

Every search comes in two flavours with the same signature:

```swift
let hits = fuse.search("old man")               // synchronous, single-threaded
let hits = try await fuse.search("old man")     // async: parallel for big collections, cancellable
```

Inside `async` code Swift picks the `async` variant automatically. It splits collections of a few
thousand items or more across cores with a task group, and throws `CancellationError` when the
calling task is cancelled — ideal for search-as-you-type:

<!-- From: Snippets/AsyncSearch.swift -->
```swift
.task(id: query) {
    results = try await fuse.search(query)   // cancelled automatically when `query` changes
}
```

`Fuse`, `FuseOptions`, `FuseKey`, `FuseQuery`, `FuseResult`, `FuseMatch` and `FuseIndex` are all
`Sendable`.

## One-off matching

`FuseMatcher` compiles a pattern once and matches it against individual strings without an index —
the Fuse.js `Fuse.match` helper.

```swift
let matcher = FuseMatcher("hllo", options: FuseOptions(includeMatches: true))
matcher.match("Hello world")   // isMatch: true, score: 0.25, indices: [0..<1, 2..<5]
```

## How scoring works

SwiftFuse implements the Fuse.js scoring pipeline exactly:

1. **Bitap** approximate matching gives each field a score of `errors / patternLength` plus a
   location penalty of `|position − location| / distance` (unless `ignoreLocation`). Patterns longer
   than 32 characters are split into chunks whose scores are averaged.
2. **Field-length norm**: each field is weighted by `1 / √tokens` (tunable with `fieldNormWeight`),
   so a match in a short field beats the same match in a long one.
3. **Weights**: key weights are normalised to sum to 1, and the item score is the product
   `∏ score ^ (weight × norm)` over all matching fields — more matching fields and heavier keys both
   pull the score towards 0. An exact match contributes `Double.ulpOfOne` rather than `0`.
4. Results are sorted by score, ties broken by collection order, then truncated to `limit`.

## Performance

Measured with `swift run -c release fuse-benchmark` on 4 cores (Linux, Swift 6.2), searching random
2–5-word strings; Fuse.js 7.5 on Node 22 with the same data for comparison.

| Items | Create | Build index | Search (sync) | Search (async) | Fuse.js search |
|---|---|---|---|---|---|
| 1,000 | 0.02 ms | 0.6 ms | 0.9 ms | 1.0 ms | 5.8 ms |
| 10,000 | 0.003 ms | 3 ms | 9.7 ms | 5.5 ms | 53 ms |
| 100,000 | 0.005 ms | 52 ms | 96 ms | 53 ms | 581 ms |

Where the time goes, and what makes it fast:

- **Integer text.** Every field is normalised once at index time into an array of `UInt32`
  character codes stored in one contiguous arena, so the matcher never touches `String`,
  `Character` or grapheme breaking. Pure-ASCII strings take a byte-wise fast path.
- **A sound pre-filter.** Each field keeps a 64-bit summary of the characters it contains. Before
  running Bitap, the pattern's characters are checked against it: a pattern character that is absent
  from the text costs at least one edit, so if more are absent than `threshold` allows, the field is
  skipped. This never changes results.
- **No allocation in the hot loop.** Bitap bit arrays and match masks are reused per worker; the
  pattern alphabet is a dense table for ASCII.
- **Parallel async search** splits the collection across cores; results merge and sort once.
- **Bounded heap for `limit`**, so asking for the top 10 of 100,000 does not sort 100,000 results.

## Testing

The test suite uses [Swift Testing](https://github.com/swiftlang/swift-testing) and runs on Linux
and macOS:

```sh
swift test
```

`Tests/FuseTests/Fixtures/fusejs-parity.json` holds ~190 cases produced by running the real Fuse.js
over the same collections, options and queries; the suite replays each one and requires identical
output (order, `refIndex`, scores to 1e-9, highlight indices). Regenerate it with Node:

```sh
cd Tests/FuseTests/Fixtures && npm install fuse.js@7 && node generate.mjs fusejs-parity.json
```

Every code block in this README marked `From: Snippets/…` is a file in [`Snippets/`](Snippets/)
that `swift build` compiles, so the examples cannot go stale. Run one with
`swift run BasicStringSearch`.

## Differences from Fuse.js

- Keys are `FuseKey` values with key paths or closures; there are no string paths or `getFn`.
  Nested or computed values are a closure away.
- Scores are always included. Match ranges are `Character` offsets into the original string (Fuse.js
  reports UTF-16 offsets into the lowercased string, which can split a grapheme).
- Multi-scalar graphemes (emoji sequences, letters with several combining marks) and expansions such
  as `ß → ss` under `ignoreDiacritics` are treated as one indivisible character.
- A blank query returns every item with a score of `0` (Fuse.js omits the score).
- Logical queries work with token search (Fuse.js 7.5 throws).
- Everything is `Sendable` and there is an `async` search; Fuse.js is single-threaded.

## License

MIT
