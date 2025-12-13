
import Foundation

/// Internal storage for preprocessed searchable data.
///
/// This struct is used internally by `Fuse` to store pre-indexed data for fast searches.
/// Users don't interact with this directly - it's created automatically when you initialize
/// a `Fuse` instance with data.
public struct FuseIndex<T: Sendable>: Sendable {
	/// A single indexed item with preprocessed searchable text
	public struct IndexedItem: Sendable {
		/// The original item
		public let item: T
		/// The original index in the source collection
		public let index: Int
		/// Preprocessed properties: key -> IndexedProperty
		public let properties: [String: IndexedProperty]
	}

	/// Preprocessed property data optimized for search
	public struct IndexedProperty: Sendable {
		/// Original string value
		public let original: String
		/// Normalized (lowercased) string for matching
		public let normalized: String
		/// Characters as array for O(1) random access during search
		public let characters: [Character]
		/// Set of unique characters for quick pre-filtering
		public let characterSet: Set<Character>
		/// Property weight for scoring
		public let weight: Double
		/// Text length (cached)
		public let length: Int
	}

	/// All indexed items
	public let items: [IndexedItem]

	/// Whether the index was created with case sensitivity
	public let isCaseSensitive: Bool
}
