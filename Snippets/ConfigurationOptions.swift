import Fuse

let words = ["test at the start", "this is a test string", "end of test", "no match here"]

// Strict matching — only very close matches.
let strict = Fuse(words, options: FuseOptions(threshold: 0.2))
print("strict:", strict.search("test").count)

// Location-independent scoring: "test" scores the same wherever it appears.
let anywhere = Fuse(words, options: FuseOptions(ignoreLocation: true))
print("ignoreLocation:", anywhere.search("test").map(\.score))

// Case-sensitive and diacritic-insensitive matching.
let exactCase = Fuse(["Hello", "hello", "HELLO"], options: FuseOptions(isCaseSensitive: true))
print("case-sensitive:", exactCase.search("hello").map(\.item))

let accents = Fuse(["Crème Brûlée", "creme brulee"], options: FuseOptions(ignoreDiacritics: true))
print("ignoreDiacritics:", accents.search("creme").count)

// Options are a plain struct — mutate what you need.
var options = FuseOptions()
options.minMatchCharLength = 3
options.includeMatches = true
options.findAllMatches = true
let configured = Fuse(words, options: options)
print("configured:", configured.search("test").first?.matches.first?.indices ?? [])
