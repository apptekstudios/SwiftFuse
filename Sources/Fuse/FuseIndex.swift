
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
		/// Preprocessed properties: key -> (originalValue, lowercasedValue, weight)
		public let properties: [String: (original: String, normalized: String, weight: Double)]
	}

	/// All indexed items
	public let items: [IndexedItem]

	/// Whether the index was created with case sensitivity
	public let isCaseSensitive: Bool
}
