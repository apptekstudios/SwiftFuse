
import Foundation


enum Utilities {
	/// Computes the score for a match with `e` errors and `x` location.
	///
	/// - Parameter pattern: Pattern being sought.
	/// - Parameter e: Number of errors in match.
	/// - Parameter x: Location of match.
	/// - Parameter loc: Expected location of match.
	/// - Parameter distance: How much location affects the score.
	/// - Parameter ignoreLocation: When true, score is based only on match accuracy.
	/// - Returns: Overall score for match (0.0 = good, 1.0 = bad).
	static func calculateScore(_ pattern: String, e: Int, x: Int, loc: Int, distance: Int, ignoreLocation: Bool = false) -> Double {
		return calculateScore(pattern.count, e: e, x: x, loc: loc, distance: distance, ignoreLocation: ignoreLocation)
	}

	/// Computes the score for a match with `e` errors and `x` location.
	///
	/// - Parameter patternLength: Length of pattern being sought.
	/// - Parameter e: Number of errors in match.
	/// - Parameter x: Location of match.
	/// - Parameter loc: Expected location of match.
	/// - Parameter distance: How much location affects the score.
	/// - Parameter ignoreLocation: When true, score is based only on match accuracy.
	/// - Returns: Overall score for match (0.0 = good, 1.0 = bad).
	static func calculateScore(_ patternLength: Int, e: Int, x: Int, loc: Int, distance: Int, ignoreLocation: Bool = false) -> Double {
		let accuracy = Double(e) / Double(patternLength)

		if ignoreLocation {
			return accuracy
		}

		let proximity = abs(x - loc)
		if distance == 0 {
			return Double(proximity != 0 ? 1 : accuracy)
		}
		return accuracy + (Double(proximity) / Double(distance))
	}

	/// Initializes the alphabet for the Bitap algorithm
	///
	/// - Parameter pattern: The text to encode.
	/// - Returns: Hash of character locations.
	static func calculatePatternAlphabet(_ pattern: String) -> [Character: Int] {
		let len = pattern.count
		var mask = [Character: Int]()
		for (i, c) in pattern.enumerated() {
			mask[c] =  (mask[c] ?? 0) | (1 << (len - i - 1))
		}
		return mask
	}

	/// Returns an array of `Range<Int>`, where each range represents a consecutive list of `1`s.
	///
	///     let arr = [0, 1, 1, 0, 1, 1, 1 ]
	///     let ranges = findRanges(arr)
	///     // [{startIndex 1, endIndex 2}, {startIndex 4, endIndex 6}
	///
	/// - Parameter mask: A string representing the value to search for.
	///
	/// - Returns: `CountableRange<Int>` array.
	static func findRanges(_ mask: [Int]) -> [Range<Int>] {
		var ranges = [Range<Int>]()
		var start: Int?
		for (n, bit) in mask.enumerated() {
			if bit == 1 {
				if start == nil {
					start = n
				}
			} else {
				if let bottomBound = start {
					ranges.append(bottomBound ..< n)
					start = nil
				}
			}
		}
		if let start, mask.last == 1 {
			ranges.append(start ..< mask.endIndex)
		}
		return ranges
	}
}
