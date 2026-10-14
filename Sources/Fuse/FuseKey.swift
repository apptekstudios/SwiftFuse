/// Describes one searchable field of an item.
///
/// A key has a ``name`` (used to identify matches and in ``FuseQuery``), a ``weight`` that controls
/// how much a match in this field contributes to the item score (higher = more important; weights are
/// normalised across keys), and a getter that extracts the text to index. Values can be a single
/// string, an optional string, or an array of strings (each element is indexed separately and
/// reported with its ``FuseMatch/refIndex``).
///
/// ```swift
/// let keys: [FuseKey<Book>] = [
///     FuseKey("title", weight: 2) { $0.title },
///     FuseKey("author", \.author),
///     FuseKey("tags", values: { $0.tags }),
/// ]
/// ```
public struct FuseKey<Item: Sendable>: Sendable, Identifiable {
    /// The text a key extracts from an item.
    public enum Value: Sendable {
        case none
        case string(String)
        case strings([String])
    }

    public let name: String
    public let weight: Double
    let getter: @Sendable (Item) -> Value

    public var id: String { name }

    public init(_ name: String, weight: Double = 1, value: @escaping @Sendable (Item) -> Value) {
        precondition(weight > 0, "FuseKey '\(name)': weight must be a positive number")
        self.name = name
        self.weight = weight
        self.getter = value
    }

    /// A key whose value is a (possibly absent) string.
    public init(_ name: String, weight: Double = 1, _ value: @escaping @Sendable (Item) -> String?) {
        self.init(name, weight: weight) { item in
            value(item).map(Value.string) ?? .none
        }
    }

    /// A key whose value is a list of strings; every element is indexed separately.
    public init(_ name: String, weight: Double = 1, values: @escaping @Sendable (Item) -> [String]) {
        self.init(name, weight: weight) { item in
            .strings(values(item))
        }
    }

    public init(_ name: String, weight: Double = 1, _ keyPath: any KeyPath<Item, String> & Sendable) {
        self.init(name, weight: weight) { item in
            .string(item[keyPath: keyPath])
        }
    }

    public init(_ name: String, weight: Double = 1, _ keyPath: any KeyPath<Item, String?> & Sendable) {
        self.init(name, weight: weight) { item in
            item[keyPath: keyPath].map(Value.string) ?? .none
        }
    }

    public init(_ name: String, weight: Double = 1, _ keyPath: any KeyPath<Item, [String]> & Sendable) {
        self.init(name, weight: weight) { item in
            .strings(item[keyPath: keyPath])
        }
    }

    /// Extracts the value for `item`.
    public func value(for item: Item) -> Value {
        getter(item)
    }

    /// A query that matches `pattern` against this key only. See ``FuseQuery``.
    public func matches(_ pattern: String) -> FuseQuery {
        .key(name, pattern: pattern)
    }
}

/// A type that declares its own search keys, so it can be searched with
/// ``Fuse/init(_:options:indexing:)`` without passing keys explicitly.
///
/// ```swift
/// struct Book: FuseSearchable {
///     var title: String
///     var author: String
///
///     static let fuseKeys: [FuseKey<Book>] = [
///         FuseKey("title", weight: 2, \.title),
///         FuseKey("author", \.author),
///     ]
/// }
/// ```
public protocol FuseSearchable: Sendable {
    static var fuseKeys: [FuseKey<Self>] { get }
}
