import Foundation

/// A compiled query that can be run against any indexed value.
enum AnySearcher: Sendable {
    case bitap(BitapPattern)
    case extended(ExtendedSearcher)
    case token(TokenSearcher)

    @inline(__always)
    func cannotMatch(bloom: UInt64) -> Bool {
        switch self {
        case .bitap(let pattern): return pattern.cannotMatch(bloom: bloom)
        case .extended(let searcher): return searcher.cannotMatch(bloom: bloom)
        case .token(let searcher): return searcher.cannotMatch(bloom: bloom)
        }
    }

    @inline(__always)
    func search(_ text: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> SearchOutcome {
        switch self {
        case .bitap(let pattern):
            return SearchOutcome(pattern.search(text, scratch: &scratch))
        case .extended(let searcher):
            return searcher.search(text, scratch: &scratch)
        case .token(let searcher):
            return searcher.search(text, scratch: &scratch)
        }
    }

    /// Fuse.js `createSearcher`.
    static func make(pattern: String, options: FuseOptions, index: FuseIndex) -> AnySearcher {
        if options.useExtendedSearch {
            return .extended(ExtendedSearcher(pattern: pattern, options: options, normalizer: index.normalizer))
        }
        if options.useTokenSearch {
            return .token(TokenSearcher(pattern: pattern, options: options, normalizer: index.normalizer, statistics: index.tokenStatistics ?? TokenStatistics()))
        }
        return .bitap(BitapPattern(codes: index.normalizer.encode(pattern), options: BitapOptions(options: options)))
    }
}

/// `FuseMatchResult` plus the extra flags Fuse.js carries alongside it.
struct SearchOutcome {
    var isMatch: Bool
    var score: Double
    var indices: [Range<Int>]
    /// Extended search: at least one inverse matcher (`!`) contributed to this match.
    var hasInverse = false
    /// Token search with `tokenMatch == .all`: indices of query terms matched by this value.
    var matchedTerms: [Int] = []

    init(_ result: FuseMatchResult) {
        isMatch = result.isMatch
        score = result.score
        indices = result.indices
    }

    init(isMatch: Bool, score: Double, indices: [Range<Int>] = []) {
        self.isMatch = isMatch
        self.score = score
        self.indices = indices
    }

    static let noMatch = SearchOutcome(isMatch: false, score: 1)
}

// MARK: - Extended search

/// Fuse.js extended search: `|` separates OR groups, spaces separate AND terms, and each term may
/// carry an operator prefix/suffix (`=`, `'`, `!`, `^`, `$`). Quoted terms may contain spaces.
struct ExtendedSearcher: Sendable {
    enum Matcher: Sendable {
        case exact([UInt32])
        case include([UInt32])
        case prefixExact([UInt32])
        case inversePrefixExact([UInt32])
        case inverseSuffixExact([UInt32])
        case suffixExact([UInt32])
        case inverseExact([UInt32])
        case fuzzy(BitapPattern)

        var isInverse: Bool {
            switch self {
            case .inversePrefixExact, .inverseSuffixExact, .inverseExact: return true
            default: return false
            }
        }
    }

    /// OR groups of AND matchers.
    let groups: [[Matcher]]
    let includeMatches: Bool

    init(pattern: String, options: FuseOptions, normalizer: TextNormalizer) {
        includeMatches = options.includeMatches
        let bitapOptions = BitapOptions(options: options)
        groups = ExtendedSearcher.parse(pattern).map { tokens in
            tokens.map { token in
                ExtendedSearcher.matcher(for: token, normalizer: normalizer, bitapOptions: bitapOptions)
            }
        }
    }

    // MARK: Parsing (Fuse.js `parseQuery` + `tokenize`)

    static func parse(_ pattern: String) -> [[String]] {
        let escaped = pattern.replacingOccurrences(of: "\\|", with: "\u{0}")
        return escaped.split(separator: "|", omittingEmptySubsequences: false).map { group in
            let text = String(group).replacingOccurrences(of: "\u{0}", with: "|")
            return tokenize(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .filter { !$0.isEmpty && !TextStats.isBlank($0) }
        }
    }

    static func tokenize(_ pattern: String) -> [String] {
        let chars = Array(pattern)
        var tokens: [String] = []
        let length = chars.count
        var i = 0
        while i < length {
            while i < length, chars[i] == " " { i += 1 }
            if i >= length { break }
            var j = i
            while j < length, chars[j] != " ", chars[j] != "\"" { j += 1 }
            if j < length, chars[j] == "\"" {
                j += 1
                while j < length {
                    if chars[j] == "\"" {
                        let next = j + 1
                        if next >= length || chars[next] == " " {
                            j += 1
                            break
                        }
                        if chars[next] == "$", next + 1 >= length || chars[next + 1] == " " {
                            j += 2
                            break
                        }
                    }
                    j += 1
                }
                tokens.append(String(chars[i ..< j]))
                i = j
            } else {
                while j < length, chars[j] != " " { j += 1 }
                tokens.append(String(chars[i ..< j]))
                i = j
            }
        }
        return tokens
    }

    private enum MatcherKind: CaseIterable {
        case exact, include, prefixExact, inversePrefixExact, inverseSuffixExact, suffixExact, inverseExact, fuzzy

        var prefix: String {
            switch self {
            case .exact: return "="
            case .include: return "'"
            case .prefixExact: return "^"
            case .inversePrefixExact: return "!^"
            case .inverseSuffixExact, .inverseExact: return "!"
            case .suffixExact, .fuzzy: return ""
            }
        }

        var suffix: String {
            switch self {
            case .inverseSuffixExact, .suffixExact: return "$"
            default: return ""
            }
        }

        /// `^<prefix>"(.*)"<suffix>$` — the quoted ("multi") form.
        func quotedPayload(_ token: String) -> String? {
            payload(token, open: prefix + "\"", close: "\"" + suffix)
        }

        /// `^<prefix>(.*)<suffix>$` — the bare ("single") form.
        func barePayload(_ token: String) -> String? {
            payload(token, open: prefix, close: suffix)
        }

        private func payload(_ token: String, open: String, close: String) -> String? {
            guard token.hasPrefix(open), token.count >= open.count + close.count else { return nil }
            var inner = token.dropFirst(open.count)
            guard inner.hasSuffix(close) else { return nil }
            inner = inner.dropLast(close.count)
            guard !inner.isEmpty, !inner.contains("\n") else { return nil }
            return String(inner)
        }
    }

    private static func matcher(for token: String, normalizer: TextNormalizer, bitapOptions: BitapOptions) -> Matcher {
        for kind in MatcherKind.allCases {
            if let payload = kind.quotedPayload(token) {
                return make(kind, payload: payload, normalizer: normalizer, bitapOptions: bitapOptions)
            }
        }
        for kind in MatcherKind.allCases {
            if let payload = kind.barePayload(token) {
                return make(kind, payload: payload, normalizer: normalizer, bitapOptions: bitapOptions)
            }
        }
        // Unreachable: the bare fuzzy form matches any non-empty token.
        return make(.fuzzy, payload: token, normalizer: normalizer, bitapOptions: bitapOptions)
    }

    private static func make(_ kind: MatcherKind, payload: String, normalizer: TextNormalizer, bitapOptions: BitapOptions) -> Matcher {
        let codes = normalizer.encode(payload)
        switch kind {
        case .exact: return .exact(codes)
        case .include: return .include(codes)
        case .prefixExact: return .prefixExact(codes)
        case .inversePrefixExact: return .inversePrefixExact(codes)
        case .inverseSuffixExact: return .inverseSuffixExact(codes)
        case .suffixExact: return .suffixExact(codes)
        case .inverseExact: return .inverseExact(codes)
        case .fuzzy: return .fuzzy(BitapPattern(codes: codes, options: bitapOptions))
        }
    }

    // MARK: Matching

    /// Sound pre-filter: a group is impossible when one of its positive matchers needs a character
    /// the text does not contain. The text can only be skipped when every group is impossible.
    func cannotMatch(bloom: UInt64) -> Bool {
        guard !groups.isEmpty else { return true }
        for group in groups {
            var impossible = false
            for matcher in group {
                switch matcher {
                case .exact(let codes), .include(let codes), .prefixExact(let codes), .suffixExact(let codes):
                    if codes.contains(where: { bloom & TextStats.bloomBit($0) == 0 }) { impossible = true }
                case .fuzzy(let pattern):
                    if pattern.cannotMatch(bloom: bloom) { impossible = true }
                case .inversePrefixExact, .inverseSuffixExact, .inverseExact:
                    break
                }
                if impossible { break }
            }
            if !impossible { return false }
        }
        return true
    }

    func search(_ text: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> SearchOutcome {
        var allIndices: [Range<Int>] = []
        for group in groups {
            var numMatches = 0
            var totalScore = 0.0
            var hasInverse = false
            allIndices.removeAll(keepingCapacity: true)
            var matchedAll = true
            for matcher in group {
                let result = run(matcher, on: text, scratch: &scratch)
                guard result.isMatch else {
                    matchedAll = false
                    break
                }
                numMatches += 1
                totalScore += result.score
                if matcher.isInverse { hasInverse = true }
                if includeMatches { allIndices.append(contentsOf: result.indices) }
            }
            if matchedAll, numMatches > 0 {
                var outcome = SearchOutcome(isMatch: true, score: totalScore / Double(numMatches), indices: includeMatches ? Bitap.mergeIndices(allIndices) : [])
                outcome.hasInverse = hasInverse
                return outcome
            }
        }
        return .noMatch
    }

    private func run(_ matcher: Matcher, on text: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> FuseMatchResult {
        let textLength = text.count
        func exactStyle(_ isMatch: Bool, indices: @autoclosure () -> [Range<Int>]) -> FuseMatchResult {
            FuseMatchResult(isMatch: isMatch, score: isMatch ? 0 : 1, indices: includeMatches ? indices() : [])
        }
        switch matcher {
        case .exact(let codes):
            let isMatch = codes.count == textLength && codes.withUnsafeBufferPointer { $0.elementsEqual(text) }
            return exactStyle(isMatch, indices: [0 ..< codes.count])
        case .include(let codes):
            var indices: [Range<Int>] = []
            var location = 0
            while let index = Bitap.indexOf(codes, in: text, from: location) {
                location = index + codes.count
                indices.append(index ..< location)
            }
            return FuseMatchResult(isMatch: !indices.isEmpty, score: indices.isEmpty ? 1 : 0, indices: includeMatches ? indices : [])
        case .prefixExact(let codes):
            return exactStyle(hasPrefix(text, codes), indices: [0 ..< codes.count])
        case .inversePrefixExact(let codes):
            return exactStyle(!hasPrefix(text, codes), indices: [0 ..< textLength])
        case .inverseSuffixExact(let codes):
            return exactStyle(!hasSuffix(text, codes), indices: [0 ..< textLength])
        case .suffixExact(let codes):
            return exactStyle(hasSuffix(text, codes), indices: [max(0, textLength - codes.count) ..< textLength])
        case .inverseExact(let codes):
            return exactStyle(Bitap.indexOf(codes, in: text, from: 0) == nil, indices: [0 ..< textLength])
        case .fuzzy(let pattern):
            return pattern.search(text, scratch: &scratch)
        }
    }

    @inline(__always)
    private func hasPrefix(_ text: UnsafeBufferPointer<UInt32>, _ codes: [UInt32]) -> Bool {
        codes.count <= text.count && codes.withUnsafeBufferPointer { $0.elementsEqual(text[0 ..< codes.count]) }
    }

    @inline(__always)
    private func hasSuffix(_ text: UnsafeBufferPointer<UInt32>, _ codes: [UInt32]) -> Bool {
        codes.count <= text.count && codes.withUnsafeBufferPointer { $0.elementsEqual(text[(text.count - codes.count)...]) }
    }
}

// MARK: - Token search

/// Fuse.js `TokenSearch`: every query term is matched independently (location-insensitive) and the
/// per-term scores are combined with BM25-style inverse document frequency weights.
struct TokenSearcher: Sendable {
    let terms: [BitapPattern]
    let idfWeights: [Double]
    let includeMatches: Bool
    let requireAll: Bool

    init(pattern: String, options: FuseOptions, normalizer: TextNormalizer, statistics: TokenStatistics) {
        includeMatches = options.includeMatches
        requireAll = options.tokenMatch == .all
        let tokenizer = options.tokenizer ?? .default
        var bitapOptions = BitapOptions(options: options)
        bitapOptions.ignoreLocation = true
        var terms: [BitapPattern] = []
        var weights: [Double] = []
        for term in tokenizer.tokenize(normalizer.normalizeString(pattern)) {
            terms.append(BitapPattern(codes: normalizer.encode(term), options: bitapOptions))
            let documentFrequency = Double(statistics.documentFrequency[term] ?? 0)
            let fieldCount = Double(statistics.fieldCount)
            weights.append(log(1 + (fieldCount - documentFrequency + 0.5) / (documentFrequency + 0.5)))
        }
        self.terms = terms
        self.idfWeights = weights
    }

    var termCount: Int { terms.count }

    func cannotMatch(bloom: UInt64) -> Bool {
        !terms.isEmpty && terms.allSatisfy { $0.cannotMatch(bloom: bloom) }
    }

    func search(_ text: UnsafeBufferPointer<UInt32>, scratch: inout BitapScratch) -> SearchOutcome {
        guard !terms.isEmpty else { return .noMatch }
        var allIndices: [Range<Int>] = []
        var weightedScore = 0.0
        var maxPossibleScore = 0.0
        var matchedCount = 0
        var matched: [Int] = []
        for (index, term) in terms.enumerated() {
            let idf = idfWeights[index]
            maxPossibleScore += idf
            let result = term.search(text, scratch: &scratch)
            if result.isMatch {
                matchedCount += 1
                weightedScore += idf * (1 - result.score)
                if includeMatches { allIndices.append(contentsOf: result.indices) }
                if requireAll { matched.append(index) }
            }
        }
        guard matchedCount > 0 else { return .noMatch }
        let normalized = maxPossibleScore > 0 ? 1 - weightedScore / maxPossibleScore : 0
        var outcome = SearchOutcome(isMatch: true, score: max(0.001, normalized), indices: includeMatches && !allIndices.isEmpty ? Bitap.mergeIndices(allIndices) : [])
        outcome.matchedTerms = matched
        return outcome
    }
}

// MARK: - Public one-off matcher

/// Matches a single pattern against individual strings without building an index — the Fuse.js
/// `Fuse.match(pattern, text, options)` helper, compiled once so it can be reused.
///
/// ```swift
/// let matcher = FuseMatcher("hllo", options: FuseOptions(includeMatches: true))
/// let result = matcher.match("Hello world")
/// result.isMatch   // true
/// result.score     // 0.25…
/// result.indices   // [0..<5]
/// ```
public struct FuseMatcher: Sendable {
    let searcher: AnySearcher
    let normalizer: TextNormalizer

    /// - Precondition: token search needs corpus statistics and is not supported here.
    public init(_ pattern: String, options: FuseOptions = .default) {
        precondition(!options.useTokenSearch, "FuseMatcher does not support useTokenSearch; use Fuse(...).search(...) instead")
        normalizer = TextNormalizer(options: options)
        if options.useExtendedSearch {
            searcher = .extended(ExtendedSearcher(pattern: pattern, options: options, normalizer: normalizer))
        } else {
            searcher = .bitap(BitapPattern(codes: normalizer.encode(pattern), options: BitapOptions(options: options)))
        }
    }

    public func match(_ text: String) -> FuseMatchResult {
        var scratch = BitapScratch()
        let codes = normalizer.encode(text)
        let outcome = codes.withUnsafeBufferPointer { searcher.search($0, scratch: &scratch) }
        return FuseMatchResult(isMatch: outcome.isMatch, score: outcome.score, indices: outcome.indices)
    }
}
