import Foundation
import Testing
@testable import Fuse

@Suite("Searching")
struct SearchingTests {
    @Test func stringsBasic() {
        let fuse = Fuse(Fixtures.names)
        let results = fuse.search("john")
        #expect(results.first?.item == "John Smith")
        #expect(results.allSatisfy { $0.score >= 0 && $0.score <= 1 })
        #expect(results.map(\.score) == results.map(\.score).sorted())
    }

    @Test func noMatches() {
        #expect(Fuse(Fixtures.names).search("qzxv").isEmpty)
    }

    @Test func blankPatternReturnsEverythingUnranked() {
        let fuse = Fuse(Fixtures.names)
        #expect(fuse.search("").map(\.refIndex) == Array(Fixtures.names.indices))
        #expect(fuse.search("   ", limit: 2).map(\.item) == Array(Fixtures.names.prefix(2)))
    }

    @Test func limitAndOrdering() {
        let fuse = Fuse(Fixtures.names)
        let all = fuse.search("jo")
        #expect(fuse.search("jo", limit: 2).map(\.refIndex) == Array(all.prefix(2).map(\.refIndex)))
        #expect(fuse.search("jo", limit: 0).isEmpty)
        let unsorted = Fuse(Fixtures.names, options: FuseOptions(shouldSort: false)).search("jo")
        #expect(unsorted.map(\.refIndex) == unsorted.map(\.refIndex).sorted())
        #expect(Set(unsorted.map(\.refIndex)) == Set(all.map(\.refIndex)))
    }

    @Test func heapLimitMatchesFullSort() {
        let items = Fixtures.words(5000)
        let fuse = Fuse(items)
        let full = snapshots(fuse.search("spinal block"))
        for limit in [1, 2, 5, 17, 100] {
            #expect(snapshots(fuse.search("spinal block", limit: limit)) == Array(full.prefix(limit)), "limit \(limit)")
        }
    }

    @Test func weightsFavourHeavierKeys() {
        let books = [
            Book(title: "Dune", author: "Frank Herbert"),
            Book(title: "Herbert's Garden", author: "Nobody"),
        ]
        let titleHeavy = Fuse(books, keys: [FuseKey("title", weight: 3, \.title), FuseKey("author", \.author)])
        #expect(titleHeavy.search("herbert").first?.item.title == "Herbert's Garden")
        let authorHeavy = Fuse(books, keys: [FuseKey("title", \.title), FuseKey("author", weight: 3, \.author)])
        #expect(authorHeavy.search("herbert").first?.item.title == "Dune")
    }

    @Test func searchableProtocolAndStaticSearch() {
        let instance = Fuse(Fixtures.books).search("woodhouse")
        #expect(Set(instance.prefix(3).map(\.item.title)) == ["Right Ho Jeeves", "Thank You Jeeves", "The Code of the Wooster"])
        #expect(snapshots(Fuse.search("woodhouse", in: Fixtures.books)) == snapshots(instance))
        #expect(snapshots(Fuse.search("john", in: Fixtures.names)) == snapshots(Fuse(Fixtures.names).search("john")))
        let keyed = Fuse.search("hawking", in: Fixtures.books, keys: [FuseKey("author", \.author)])
        #expect(keyed.map(\.item.title) == ["The Grand Design"])
    }

    @Test func staticAsyncSearch() async throws {
        let instance = syncSearch(Fuse(Fixtures.books), "woodhouse")
        #expect(snapshots(try await Fuse.search("woodhouse", in: Fixtures.books)) == snapshots(instance))
        #expect(snapshots(try await Fuse.search("john", in: Fixtures.names)) == snapshots(syncSearch(Fuse(Fixtures.names), "john")))
        let keyed = try await Fuse.search("hawking", in: Fixtures.books, keys: [FuseKey("author", \.author)])
        #expect(keyed.map(\.item.title) == ["The Grand Design"])
    }

    @Test func optionalAndArrayValues() {
        let fuse = Fuse(Fixtures.books, options: FuseOptions(includeMatches: true))
        let isbn = fuse.search("0765348272")
        #expect(isbn.first?.item.title == "Old Man's War")
        #expect(isbn.first?.matches.first?.key == "isbn")
        let tags = fuse.search("thriller", limit: 4)
        #expect(tags.allSatisfy { $0.item.tags.contains("thriller") })
        let match = tags.first?.matches.first { $0.key == "tags" }
        #expect(match?.refIndex == tags.first?.item.tags.firstIndex(of: "thriller"))
        #expect(match?.value == "thriller")
        #expect(match?.indices == [0 ..< 8])
    }

    @Test func keyPathsAndClosuresAgree() {
        let closures = Fuse(Fixtures.books, keys: [FuseKey("title") { $0.title }, FuseKey("tags", values: { $0.tags })])
        let keyPaths = Fuse(Fixtures.books, keys: [FuseKey("title", \.title), FuseKey("tags", \.tags)])
        #expect(snapshots(closures.search("code")) == snapshots(keyPaths.search("code")))
    }

    @Test func queryLiteralsAndKeyHelpers() {
        let fuse = Fuse(Fixtures.books, options: FuseOptions(threshold: 0.3))
        let title = Book.fuseKeys[0]
        let author = Book.fuseKeys[1]
        let results = fuse.search(.and(["code", author.matches("brown")]))
        #expect(results.map(\.item.title) == ["The DaVinci Code"])
        #expect(fuse.search(.or([title.matches("lamb"), title.matches("syrup")])).count == 2)
        #expect(fuse.search(.and([])).isEmpty)
    }

    @Test func longPatternsAreChunked() {
        let text = "a very long sentence that keeps going well past thirty two characters so that it needs chunking"
        let fuse = Fuse([text, "short"], options: FuseOptions(includeMatches: true))
        let results = fuse.search(String(text.prefix(70)))
        #expect(results.count == 1)
        // Fuse.js averages the three 32-character chunk scores (the re-anchored last chunk pays a
        // location penalty), so the result is good but not perfect: 0.1866 in Fuse.js too.
        #expect(approximatelyEqual(results.first?.score ?? 1, 0.186637969083467))
        #expect(results.first?.matches.first?.indices == [0 ..< 70])
    }

    @Test func matcher() {
        let matcher = FuseMatcher("hllo", options: FuseOptions(includeMatches: true))
        let hit = matcher.match("Hello world")
        #expect(hit.isMatch)
        #expect(hit.indices == [0 ..< 1, 2 ..< 5])   // Fuse.js highlights only characters of the pattern
        #expect(hit.score == 0.25)
        #expect(!matcher.match("xyz").isMatch)
        // A collection search additionally applies the field-length norm; disable it to compare.
        let viaFuse = Fuse(["Hello world"], options: FuseOptions(includeMatches: true, ignoreFieldNorm: true)).search("hllo").first!
        #expect(approximatelyEqual(viaFuse.score, hit.score))
        #expect(viaFuse.matches.first?.indices == hit.indices)
        let extended = FuseMatcher("^hello !world", options: FuseOptions(useExtendedSearch: true))
        #expect(extended.match("hello there").isMatch)
        #expect(!extended.match("hello world").isMatch)
    }
}

@Suite("Match ranges")
struct RangeTests {
    @Test func rangesAreValidOnOriginalStrings() {
        let fuse = Fuse(Fixtures.unicode, options: FuseOptions(includeMatches: true, threshold: 0.4, ignoreLocation: true))
        for query in ["apple", "pie", "picnic", "clair", "mir", "break", "brulee", "日本"] {
            for result in fuse.search(query) {
                for match in result.matches {
                    let ranges = match.ranges
                    #expect(ranges.count == match.indices.count)
                    for (range, offsets) in zip(ranges, match.indices) {
                        let expected = String(Array(match.value)[offsets])
                        #expect(String(match.value[range]) == expected, "\(query) in \(match.value)")
                    }
                }
            }
        }
    }

    @Test func emojiAndCombiningMarksCountAsOneCharacter() {
        let fuse = Fuse(["👨‍👩‍👧 family picnic"], options: FuseOptions(includeMatches: true))
        let match = fuse.search("family").first!.matches.first!
        #expect(match.indices == [2 ..< 8])
        #expect(String(match.value[match.ranges[0]]) == "family")
    }

    @Test func diacriticsCaseFoldingKeepsAlignment() {
        let fuse = Fuse(["ÉCLAIR au café", "e\u{301}clair"], options: FuseOptions(ignoreDiacritics: true, includeMatches: true))
        let results = fuse.search("eclair")
        #expect(results.count == 2)
        for result in results {
            let match = result.matches[0]
            #expect(match.indices == [0 ..< 6])
            #expect(String(match.value[match.ranges[0]]).count == 6)
        }
    }

    @Test func crlfIsOneCharacter() {
        let fuse = Fuse(["line\r\nbreak"], options: FuseOptions(includeMatches: true, ignoreLocation: true))
        let match = fuse.search("break").first!.matches[0]
        #expect(match.indices == [5 ..< 10])
        #expect(String(match.value[match.ranges[0]]) == "break")
    }
}

@Suite("Indexing and concurrency")
struct IndexingTests {
    @Test func lazyByDefault() {
        let fuse = Fuse(Fixtures.names)
        #expect(!fuse.isIndexed)
        _ = fuse.search("john")
        #expect(fuse.isIndexed)
    }

    @Test func strategies() async {
        let immediate = Fuse(Fixtures.names, indexing: .immediate)
        #expect(immediate.isIndexed)
        let background = Fuse(Fixtures.words(20_000), indexing: .background)
        await background.prepare()
        #expect(background.isIndexed)
        let lazy = Fuse(Fixtures.names)
        await lazy.prepare()
        #expect(lazy.isIndexed)
    }

    @Test func concurrentSearchesShareOneBuild() async throws {
        let items = Fixtures.words(30_000)
        let fuse = Fuse(items)
        let expected = snapshots(syncSearch(fuse, "knee replacement"))
        let fresh = Fuse(items)
        try await withThrowingTaskGroup(of: [ResultSnapshot].self) { group in
            for _ in 0 ..< 32 {
                group.addTask { snapshots(try await fresh.search("knee replacement")) }
            }
            for try await results in group {
                #expect(results == expected)
            }
        }
        #expect(fresh.isIndexed)
    }

    @Test func parallelAsyncSearchMatchesSync() async throws {
        let items = Fixtures.words(50_000)
        let fuse = Fuse(items, options: FuseOptions(includeMatches: true))
        for query in ["spinal", "lap chole", "dental extraction", "zzz"] {
            #expect(snapshots(try await fuse.search(query)) == snapshots(syncSearch(fuse, query)), "\(query)")
            #expect(snapshots(try await fuse.search(query, limit: 7)) == snapshots(syncSearch(fuse, query, limit: 7)), "\(query)")
        }
    }

    @Test func cancellation() async {
        let fuse = Fuse(Fixtures.words(200_000))
        let task = Task { try await fuse.search("spinal") }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func createIndexRoundTripsThroughCodable() throws {
        let keys = Book.fuseKeys
        let options = FuseOptions(useTokenSearch: true)
        let index = Fuse.createIndex(Fixtures.books, keys: keys, options: options)
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(FuseIndex.self, from: data)
        #expect(decoded.itemCount == Fixtures.books.count)
        #expect(decoded.keyNames == keys.map(\.name))
        let restored = Fuse(Fixtures.books, keys: keys, index: decoded, options: options)
        let fresh = Fuse(Fixtures.books, keys: keys, options: options)
        for query in ["dan brown", "jeeves", "code", "sci"] {
            #expect(snapshots(restored.search(query)) == snapshots(fresh.search(query)))
        }
        #expect(!index.isCompatible(with: FuseOptions(isCaseSensitive: true)))
    }

    @Test func indexPropertyBuildsOnDemand() {
        let fuse = Fuse(Fixtures.names)
        #expect(fuse.index.itemCount == Fixtures.names.count)
        #expect(fuse.index.recordCount == Fixtures.names.count)
        #expect(fuse.isIndexed)
    }
}

@Suite("Mutation")
struct MutationTests {
    private func assertEqualToFresh(_ fuse: Fuse<Book>, _ items: [Book], options: FuseOptions = .default, queries: [String] = ["code", "brown", "jeeves", "the", "sci"]) {
        #expect(fuse.items == items)
        let fresh = Fuse(items, options: options)
        for query in queries {
            #expect(snapshots(fuse.search(query)) == snapshots(fresh.search(query)), "query \(query)")
        }
    }

    @Test(arguments: [FuseOptions.default, FuseOptions(useTokenSearch: true), FuseOptions(includeMatches: true)])
    func addRemoveAndSetItems(options: FuseOptions) {
        var items = Fixtures.books
        let fuse = Fuse(items, options: options, indexing: .immediate)

        let extra = Book(title: "The Code Book", author: "Simon Singh", tags: ["code", "science"])
        fuse.add(extra)
        items.append(extra)
        assertEqualToFresh(fuse, items, options: options)

        let removed = fuse.remove { book, _ in book.author == "Dan Brown" }
        #expect(removed.count == 3)
        items.removeAll { $0.author == "Dan Brown" }
        assertEqualToFresh(fuse, items, options: options)

        let first = fuse.remove(at: 0)
        #expect(first.title == "Old Man's War")
        items.remove(at: 0)
        assertEqualToFresh(fuse, items, options: options)

        fuse.add(contentsOf: Array(Fixtures.books.prefix(3)))
        items.append(contentsOf: Fixtures.books.prefix(3))
        assertEqualToFresh(fuse, items, options: options)

        fuse.setItems(Array(Fixtures.books.suffix(4)))
        #expect(!fuse.isIndexed)
        assertEqualToFresh(fuse, Array(Fixtures.books.suffix(4)), options: options)
    }

    @Test func mutationBeforeIndexingIsFine() {
        let fuse = Fuse(Fixtures.books)
        fuse.add(Book(title: "Extra", author: "Someone"))
        fuse.remove(at: 1)
        var items = Fixtures.books
        items.append(Book(title: "Extra", author: "Someone"))
        items.remove(at: 1)
        assertEqualToFresh(fuse, items, queries: ["extra", "code"])
    }

    @Test func removeNothing() {
        let fuse = Fuse(Fixtures.books, indexing: .immediate)
        #expect(fuse.remove { _, _ in false }.isEmpty)
        #expect(fuse.count == Fixtures.books.count)
    }
}

@Suite("Internals")
struct InternalTests {
    @Test func prefilterIsSound() {
        var rng = SplitMix64(state: 99)
        let alphabet = Array("abcdefgh ")
        let normalizer = TextNormalizer()
        var scratch = BitapScratch()
        for threshold in [0.0, 0.2, 0.4, 0.6, 0.8] {
            var options = FuseOptions()
            options.threshold = threshold
            var skipped = 0
            for _ in 0 ..< 400 {
                let text = String((0 ..< Int.random(in: 1 ... 20, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                let query = String((0 ..< Int.random(in: 1 ... 8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                let pattern = BitapPattern(codes: normalizer.encode(query), options: BitapOptions(options: options))
                let codes = normalizer.encode(text)
                let bloom = codes.withUnsafeBufferPointer { TextStats.bloom($0) }
                if pattern.cannotMatch(bloom: bloom) {
                    skipped += 1
                    let result = codes.withUnsafeBufferPointer { pattern.search($0, scratch: &scratch) }
                    #expect(!result.isMatch, "prefilter skipped a real match: '\(query)' in '\(text)' @ \(threshold)")
                }
            }
            if threshold < 0.5 { #expect(skipped > 0, "prefilter never fired at threshold \(threshold)") }
        }
    }

    @Test func encodingStatistics() {
        let normalizer = TextNormalizer()
        var out: [UInt32] = []
        var cache: [Character: UInt32] = [:]
        let ascii = normalizer.encode("Hello  World\tfoo", into: &out, cache: &cache)
        #expect(ascii.length == 16)
        #expect(ascii.tokenCount == 3)
        #expect(!ascii.isBlank)
        #expect(out == normalizer.encode("hello  world\tfoo"))
        let blank = normalizer.encode("  \t ", into: &out, cache: &cache)
        #expect(blank.isBlank && blank.tokenCount == 1)
        let unicode = normalizer.encode("Zoë 🍎", into: &out, cache: &cache)
        #expect(unicode.length == 5 && unicode.tokenCount == 2 && !unicode.isBlank)
        let caseSensitive = TextNormalizer(isCaseSensitive: true)
        #expect(caseSensitive.encode("AbC") == [65, 98, 67])
        #expect(TextNormalizer(ignoreDiacritics: true).encode("Crème Łódź Ørsted") == TextNormalizer().encode("creme lodz orsted"))
        // Multi-scalar graphemes and expansions ("ß" → "ss") become a single hashed code.
        #expect(TextNormalizer().encode("👨‍👩‍👧").count == 1)
        #expect(TextNormalizer().encode("👨‍👩‍👧")[0] >= 0x8000_0000)
    }

    @Test func fieldNormMatchesFuseJS() {
        var norm = FieldNorm(weight: 1)
        #expect(norm.value(forTokenCount: 1) == 1)
        #expect(norm.value(forTokenCount: 2) == 0.707)
        #expect(norm.value(forTokenCount: 3) == 0.577)
        var weighted = FieldNorm(weight: 2)
        #expect(weighted.value(forTokenCount: 4) == 0.25)
    }

    @Test func extendedTokenizer() {
        #expect(ExtendedSearcher.tokenize("hello world") == ["hello", "world"])
        #expect(ExtendedSearcher.tokenize("\"hello world\" !foo") == ["\"hello world\"", "!foo"])
        #expect(ExtendedSearcher.tokenize("'\"book of\"$ bar") == ["'\"book of\"$", "bar"])
        #expect(ExtendedSearcher.parse("a b | c") == [["a", "b"], ["c"]])
        #expect(ExtendedSearcher.parse("red \\| dwarf") == [["red", "|", "dwarf"]])
    }
}
