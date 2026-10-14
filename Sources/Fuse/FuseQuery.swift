/// A logical search expression (the Fuse.js `$and` / `$or` / `$path` query object).
///
/// ```swift
/// let results = fuse.search(.and([
///     .key("title", pattern: "old war"),
///     .or([.key("author", pattern: "scalzi"), .key("author", pattern: "heinlein")]),
/// ]))
/// ```
///
/// Leaves use the same matcher as a plain string search (Bitap, or extended / token search when
/// enabled in ``FuseOptions``). A ``pattern(_:)`` leaf searches every key, like a plain
/// `search(_:)`. String literals are `pattern` leaves, so `.and(["old", authorKey.matches("x")])`
/// reads naturally.
public indirect enum FuseQuery: Sendable, Hashable {
    /// Match `pattern` against every key.
    case pattern(String)
    /// Match `pattern` against the key named `name` only.
    case key(_ name: String, pattern: String)
    /// Every sub-query must match.
    case and([FuseQuery])
    /// At least one sub-query must match.
    case or([FuseQuery])
}

extension FuseQuery: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .pattern(value)
    }
}
