/// Configuration for a ``Fuse`` instance.
///
/// Every option mirrors the Fuse.js option of the same name and uses the same default, so the
/// [Fuse.js documentation](https://www.fusejs.io/api/options.html) applies directly. The only
/// Fuse.js options without a counterpart are `includeScore` (scores are always included — they are
/// free to compute) and `keys` / `getFn` (keys are passed to ``Fuse/init(_:keys:options:indexing:)``
/// as type-safe ``FuseKey`` values).
public struct FuseOptions: Sendable {
    // MARK: Basic

    /// Indicates whether comparisons should be case sensitive. Default `false`.
    public var isCaseSensitive: Bool

    /// Strip diacritics (accents) from both the indexed text and the pattern before matching.
    /// Default `false`.
    public var ignoreDiacritics: Bool

    /// Whether ``FuseResult/matches`` should be populated with the matched values and the
    /// character ranges that matched. Computing ranges costs an extra pass over each matching
    /// value, so it is off by default. Default `false`.
    public var includeMatches: Bool

    /// Only matches whose length exceeds this value are returned. Default `1`.
    public var minMatchCharLength: Int

    /// Whether to sort the results by score. Default `true`.
    public var shouldSort: Bool

    /// When `true`, the matching function continues to the end of a search pattern even if a
    /// perfect match has already been located. Default `false`.
    public var findAllMatches: Bool

    // MARK: Fuzzy matching

    /// Approximately where in the text the pattern is expected to be found. Default `0`.
    public var location: Int

    /// At what point the match algorithm gives up. `0.0` requires a perfect match (of both letters
    /// and location); `1.0` matches anything. Default `0.6`.
    public var threshold: Double

    /// Determines how close the match must be to the fuzzy ``location``. An exact letter match
    /// that is `distance` characters away from ``location`` scores as a complete mismatch.
    /// Default `100`.
    public var distance: Int

    /// When `true`, the score ignores where in the string the pattern is found. Default `false`.
    public var ignoreLocation: Bool

    // MARK: Advanced

    /// When `true`, the field-length norm is not used to weight scores (shorter fields normally
    /// score better than longer ones). Default `false`.
    public var ignoreFieldNorm: Bool

    /// How much the field-length norm affects scoring. `0` is equivalent to ``ignoreFieldNorm``;
    /// higher values increase the effect. Default `1`.
    public var fieldNormWeight: Double

    /// Enables the Fuse.js extended-search syntax (`=exact`, `'include`, `!inverse`, `^prefix`,
    /// `suffix$`, space = AND, `|` = OR). Default `false`.
    public var useExtendedSearch: Bool

    /// Enables token search: the query and every value are split into terms, each term is fuzzily
    /// matched on its own and the results are combined with IDF term weighting. Default `false`.
    public var useTokenSearch: Bool

    /// For token search, whether any (`.any`) or all (`.all`) query terms must match. Default `.any`.
    public var tokenMatch: TokenMatch

    /// Custom tokenizer for token search. `nil` uses the default (runs of letters, marks, numbers
    /// and `_`).
    public var tokenizer: FuseTokenizer?

    public enum TokenMatch: Sendable, Hashable {
        /// A value matches when at least one query term matches it.
        case any
        /// An item matches only when every query term matches somewhere in it.
        case all
    }

    public init(
        isCaseSensitive: Bool = false,
        ignoreDiacritics: Bool = false,
        includeMatches: Bool = false,
        minMatchCharLength: Int = 1,
        shouldSort: Bool = true,
        findAllMatches: Bool = false,
        location: Int = 0,
        threshold: Double = 0.6,
        distance: Int = 100,
        ignoreLocation: Bool = false,
        ignoreFieldNorm: Bool = false,
        fieldNormWeight: Double = 1,
        useExtendedSearch: Bool = false,
        useTokenSearch: Bool = false,
        tokenMatch: TokenMatch = .any,
        tokenizer: FuseTokenizer? = nil
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.ignoreDiacritics = ignoreDiacritics
        self.includeMatches = includeMatches
        self.minMatchCharLength = minMatchCharLength
        self.shouldSort = shouldSort
        self.findAllMatches = findAllMatches
        self.location = location
        self.threshold = threshold
        self.distance = distance
        self.ignoreLocation = ignoreLocation
        self.ignoreFieldNorm = ignoreFieldNorm
        self.fieldNormWeight = fieldNormWeight
        self.useExtendedSearch = useExtendedSearch
        self.useTokenSearch = useTokenSearch
        self.tokenMatch = tokenMatch
        self.tokenizer = tokenizer
    }

    /// The Fuse.js defaults.
    public static let `default` = FuseOptions()
}

/// Splits already-normalised text into search terms for token search.
public struct FuseTokenizer: Sendable {
    public let tokenize: @Sendable (String) -> [String]

    public init(_ tokenize: @escaping @Sendable (String) -> [String]) {
        self.tokenize = tokenize
    }

    /// Runs of letters, combining marks, numbers and `_` — the Fuse.js default
    /// (`/[\p{L}\p{M}\p{N}_]+/gu`).
    public static let `default` = FuseTokenizer { text in
        var tokens: [String] = []
        var current = ""
        for character in text {
            if FuseTokenizer.isTokenCharacter(character) {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func isTokenCharacter(_ character: Character) -> Bool {
        if character == "_" || character.isLetter || character.isNumber {
            return true
        }
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
