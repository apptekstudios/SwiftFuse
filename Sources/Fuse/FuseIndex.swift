
import Foundation

/// A preprocessed index for fast repeated fuzzy searches on the same dataset.
///
/// Use `FuseIndex` when you need to perform multiple searches on the same collection.
/// The index pre-computes lowercased text and caches property metadata, avoiding
/// redundant work on each search.
///
/// ## Example - String Array
///
///     let fuse = Fuse()
///     let names = ["John", "Jane", "Bob", "Alice"]
///     let index = fuse.createIndex(from: names)
///
///     // Fast repeated searches
///     let results1 = fuse.search("jon", in: index)
///     let results2 = fuse.search("ali", in: index)
///
/// ## Example - Fuseable Objects
///
///     let books: [Book] = [...]
///     let index = fuse.createIndex(from: books)
///
///     // Fast repeated searches
///     let results1 = fuse.search("tolkien", in: index)
///     let results2 = fuse.search("rings", in: index)
///
@FuseActor
public struct FuseIndex<T> {
	/// A single indexed item with preprocessed searchable text
	public struct IndexedItem {
		/// The original item
		public let item: T
		/// The original index in the source collection
		public let index: Int
		/// Preprocessed properties: key -> (originalValue, lowercasedValue, weight)
		public let properties: [String: (original: String, normalized: String, weight: Double)]
	}

	/// All indexed items
	public let items: [IndexedItem]

	/// Whether the index was created with case sensitivity
	public let isCaseSensitive: Bool
}

/// Convenience type alias for string-based indexes
public typealias StringFuseIndex = FuseIndex<String>

/// Convenience type alias for Fuseable-based indexes
public typealias FuseableIndex<T: Fuseable> = FuseIndex<T>
