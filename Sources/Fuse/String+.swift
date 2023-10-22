
import Foundation

extension String {
	func index(fromOffset offset: Int) -> String.Index {
		index(startIndex, offsetBy: offset)
	}
	
	func range(from offsetRange: Range<Int>) -> Range<String.Index> {
		let start = index(fromOffset: offsetRange.lowerBound)
		let end = index(fromOffset: offsetRange.upperBound)
		return start ..< end
	}
	
//	
//	/// Get the character at a given index
//	///
//	/// - Parameter index: some index
//	/// - Returns: the character at the provided index
//	func char(at index: Int) -> Character? {
//		if index >= self.count {
//			return nil
//		}
//		return self[self.index(self.startIndex, offsetBy: index)]
//	}

	/// Searches and returns the index within the string of the first occurrence of `searchStr`.
	///
	///  - Parameter aString: A string representing the value to search for.
	///  - Parameter position: The index at which to start the searching forwards in the string. It can be any integer. The default value is 0, so the whole string is searched. If `position < 0` the entire string is searched. If `position >= str.length`, the string is not searched and `nil` is returned. Unless `searchStr` is an empty string, then str.length is returned.
	///
	///  - Returns: The index within the calling String object of the first occurrence of `searchStr`, starting the search at `position`. Returns `nil` if the value is not found.
	func index(of aString: String, startingFrom position: Int? = 0) -> String.Index? {
		guard let position = position else {
			return nil
		}
		let range = index(fromOffset: position) ..< endIndex
		guard range.lowerBound < range.upperBound else { return nil }
		return self.range(of: aString, options: .literal, range: range, locale: nil)?.lowerBound
	}

}
