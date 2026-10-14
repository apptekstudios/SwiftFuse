/// One search hit.
public struct FuseResult<Item: Sendable>: Sendable {
    /// The matched item.
    public let item: Item
    /// The item's position in the collection that was searched.
    public let refIndex: Int
    /// `0` is a perfect match, `1` a complete mismatch. Results are sorted ascending by score unless
    /// ``FuseOptions/shouldSort`` is `false`.
    public let score: Double
    /// Per-field match details. Only populated when ``FuseOptions/includeMatches`` is `true`.
    public let matches: [FuseMatch]

    public init(item: Item, refIndex: Int, score: Double, matches: [FuseMatch] = []) {
        self.item = item
        self.refIndex = refIndex
        self.score = score
        self.matches = matches
    }
}

/// Where a pattern matched inside one field value.
public struct FuseMatch: Sendable, Hashable {
    /// The ``FuseKey/name`` of the field, or `nil` when searching a plain `[String]` collection.
    public let key: String?
    /// The original (un-normalised) text of the field.
    public let value: String
    /// For array-valued keys, the index of the element within the array.
    public let refIndex: Int?
    /// Matched spans as `Character` offsets into ``value``, sorted and non-overlapping.
    public let indices: [Range<Int>]

    public init(key: String?, value: String, refIndex: Int?, indices: [Range<Int>]) {
        self.key = key
        self.value = value
        self.refIndex = refIndex
        self.indices = indices
    }

    /// ``indices`` converted to `String.Index` ranges into ``value``, ready for highlighting.
    ///
    /// Offsets are counted in `Character`s of the original string, so the ranges are always valid
    /// even for text containing emoji or combining marks.
    public var ranges: [Range<String.Index>] {
        FuseMatch.ranges(indices, in: value)
    }

    static func ranges(_ indices: [Range<Int>], in value: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        result.reserveCapacity(indices.count)
        var cursor = value.startIndex
        var offset = 0
        for range in indices {
            guard range.lowerBound >= offset else { continue }
            cursor = value.index(cursor, offsetBy: range.lowerBound - offset)
            let end = value.index(cursor, offsetBy: range.count)
            result.append(cursor ..< end)
            cursor = end
            offset = range.upperBound
        }
        return result
    }
}

/// The outcome of matching a single pattern against a single string (see ``FuseMatcher``).
public struct FuseMatchResult: Sendable, Hashable {
    public let isMatch: Bool
    /// `0` is a perfect match, `1` a complete mismatch.
    public let score: Double
    /// Matched spans as `Character` offsets. Only populated when ``FuseOptions/includeMatches``
    /// is `true`.
    public let indices: [Range<Int>]

    public init(isMatch: Bool, score: Double, indices: [Range<Int>] = []) {
        self.isMatch = isMatch
        self.score = score
        self.indices = indices
    }

    public static let noMatch = FuseMatchResult(isMatch: false, score: 1)
}
