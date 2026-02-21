import Fuse

let words = [
    "test at the start",
    "this is a test string",
    "end of test",
    "no match here",
]

// Strict threshold -- only very close matches
let strict = Fuse(data: words, threshold: 0.2)
let strictResults = try await strict.search("test")
print("Strict (threshold 0.2): \(strictResults.count) results")

// Case-sensitive matching
let caseSensitive = Fuse(data: ["Hello", "hello", "HELLO"], isCaseSensitive: true)
let csResults = try await caseSensitive.search("hello")
print("Case-sensitive: \(csResults.count) results")

// Tokenized search -- matches individual words and full string
let tokenized = Fuse(data: ["Old Man's War", "The Old Republic"], tokenize: true)
let tokenResults = try await tokenized.search("old war")
print("Tokenized: \(tokenResults.count) results")

// Ignore location -- score based only on match accuracy
let locationFree = Fuse(data: words, ignoreLocation: true)
let locResults = try await locationFree.search("test")
print("Ignore location: \(locResults.count) results")
for r in locResults {
    print("  \(r.item) -- score: \(r.score)")
}

// Static method with configuration
let staticResults = try await Fuse<String>.search(
    "test",
    in: words,
    threshold: 0.3,
    ignoreLocation: true
)
print("Static with config: \(staticResults.count) results")
