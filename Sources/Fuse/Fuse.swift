

import Foundation

@globalActor
public actor FuseActor {
	public static let shared = FuseActor()
}

@FuseActor
public class Fuse {
	private var location: Int
	private var distance: Int
	private var threshold: Double
	private var maxPatternLength: Int
	private var isCaseSensitive: Bool
	private var tokenize: Bool
	
	public typealias Pattern = (text: String, len: Int, mask: Int, alphabet: [Character: Int])
	
	public struct StringSearchResult {
		public var string: String
		public var index: Int
		public var result: ResultItem
	}
	
	public struct FusableSearchResult<T> {
		public var item: T
		public var score: Double
		public var resultsByKey: [String: ResultItem]
		
		
	}
	public struct ResultItem {
		public var score: Double
		public var ranges: [Range<String.Index>]
	}

	
	/// Creates a new instance of `Fuse`
	///
	/// - Parameters:
	///   - location: Approximately where in the text is the pattern expected to be found. Defaults to `0`
	///   - distance: Determines how close the match must be to the fuzzy `location` (specified above). An exact letter match which is `distance` characters away from the fuzzy location would score as a complete mismatch. A distance of `0` requires the match be at the exact `location` specified, a `distance` of `1000` would require a perfect match to be within `800` characters of the fuzzy location to be found using a 0.8 threshold. Defaults to `100`
	///   - threshold: At what point does the match algorithm give up. A threshold of `0.0` requires a perfect match (of both letters and location), a threshold of `1.0` would match anything. Defaults to `0.6`
	///   - maxPatternLength: The maximum valid pattern length. The longer the pattern, the more intensive the search operation will be. If the pattern exceeds the `maxPatternLength`, the `search` operation will return `nil`. Why is this important? [Read this](https://en.wikipedia.org/wiki/Word_(computer_architecture)#Word_size_choice). Defaults to `32`
	///   - isCaseSensitive: Indicates whether comparisons should be case sensitive. Defaults to `false`
	///   - tokenize: When true, the search algorithm will search individual words **and** the full string, computing the final score as a function of both. Note that when `tokenize` is `true`, the `threshold`, `distance`, and `location` are inconsequential for individual tokens.
	public init (location: Int = 0, distance: Int = 100, threshold: Double = 0.6, maxPatternLength: Int = 32, isCaseSensitive: Bool = false, tokenize: Bool = false) {
		self.location = location
		self.distance = distance
		self.threshold = threshold
		self.maxPatternLength = maxPatternLength
		self.isCaseSensitive = isCaseSensitive
		self.tokenize = tokenize
	}
	
	/// Creates a pattern tuple.
	///
	/// - Parameter aString: A string from which to create the pattern tuple
	/// - Returns: A tuple containing pattern metadata
	public func createPattern (from aString: String) -> Pattern? {
		let pattern = String((self.isCaseSensitive ? aString : aString.lowercased()).prefix(Int.bitWidth - 1))
		let len = pattern.count
		
		if len == 0 {
			return nil
		}
		
		return (
			text: pattern,
			len: len,
			mask: 1 << (len - 1),
			alphabet: Utilities.calculatePatternAlphabet(pattern)
		)
	}
	
	/// Searches for a pattern in a given string.
	///
	///     let fuse = Fuse()
	///     let pattern = fuse(from: "some text")
	///     fuse(pattern, in: "some string")
	///
	/// - Parameters:
	///   - pattern: The pattern to search for. This is created by calling `createPattern`
	///   - aString: The string in which to search for the pattern
	/// - Returns: A tuple containing a `score` between `0.0` (exact match) and `1` (not a match), and `ranges` of the matched characters. If no match is found will return nil.
	public func search(_ pattern: Pattern?, in aString: String) -> ResultItem? {
		guard let pattern = pattern else {
			return nil
		}
		
		//If tokenize is set we will split the pattern into individual words and take the average which should result in more accurate matches
		if tokenize {
			//Split this pattern by the space character
			let wordPatterns = pattern.text.split(separator: " ").compactMap { createPattern(from: String($0)) }
			
			//Get the result for testing the full pattern string. If 2 strings have equal individual word matches this will boost the full string that matches best overall to the top
			let fullPatternResult = _search(pattern, in: aString)
			
			//Reduce all the word pattern matches and the full pattern match into a totals tuple
			let results = wordPatterns.reduce(into: fullPatternResult) { (totalResult, pattern) in
				let result = _search(pattern, in: aString)
				totalResult = .init(score: totalResult.score + result.score, ranges: totalResult.ranges + result.ranges)
			}
			
			//Average the total score by dividing the summed scores by the number of word searches + the full string search. Also remove any range duplicates since we are searching full string and words individually.
			let averagedResult = ResultItem(score: results.score / Double(wordPatterns.count + 1), ranges: Array<Range<String.Index>>(Set<Range<String.Index>>(results.ranges)))
			
			//If the averaged score is 1 then there were no matches so return nil. Otherwise return the average result
			return averagedResult.score == 1 ? nil : averagedResult
			
		} else {
			let result = _search(pattern, in: aString)

			//If the averaged score is 1 then there were no matches so return nil. Otherwise return the average result
			return result.score == 1 ? nil : result
			
		}
	}
	
	/// Searches for a pattern in a given string.
	///
	///     _search(pattern, in: "some string")
	///
	/// - Parameters:
	///   - pattern: The pattern to search for. This is created by calling `createPattern`
	///   - aString: The string in which to search for the pattern
	/// - Returns: A tuple containing a `score` between `0.0` (exact match) and `1` (not a match), and `ranges` of the matched characters. If no match is found will return a tuple with score of 1 and empty array of ranges.
	private func _search(_ pattern: Pattern, in aString: String) -> ResultItem {
		let text = self.isCaseSensitive ? aString : aString.lowercased()
		return _search(pattern, in: aString, normalizedText: text)
	}

	/// Searches for a pattern in a given string using pre-normalized text.
	///
	/// This variant is used by `FuseIndex` to avoid re-lowercasing on each search.
	///
	/// - Parameters:
	///   - pattern: The pattern to search for. This is created by calling `createPattern`
	///   - originalString: The original string (used for result ranges)
	///   - normalizedText: The pre-normalized (lowercased if case-insensitive) text to search
	/// - Returns: A tuple containing a `score` between `0.0` (exact match) and `1` (not a match), and `ranges` of the matched characters.
	private func _search(_ pattern: Pattern, in originalString: String, normalizedText text: String) -> ResultItem {
		
		let textLength = text.count
		
		// Exact match
		if (pattern.text == text) {
			return .init(score: 0, ranges: [text.startIndex ..< text.endIndex])
		}
		
		let location = self.location
		let distance = self.distance
		var threshold = self.threshold
		
		var bestLocation: Int? = {
			if let index = text.index(of: pattern.text, startingFrom: location) {
				return text.distance(from: text.startIndex, to: index)
			}
			return nil
		}()
		
		// A mask of the matches. We'll use to determine all the ranges of the matches
		var matchMaskArr = [Int](repeating: 0, count: textLength)
		
		// Get all exact matches, here for speed up
		var index = text.index(of: pattern.text, startingFrom: bestLocation)
		while (index != nil) {
			let i = text.distance(from: text.startIndex, to: index!)
			let score = Utilities.calculateScore(pattern.len,
													 e: 0,
													 x: i,
													 loc: location,
													 distance: distance)
			threshold = min(threshold, score)
			bestLocation = i + pattern.len
			index = text.index(of: pattern.text, startingFrom: bestLocation)
			
			var idx = 0
			while (idx < pattern.len) {
			  matchMaskArr[i + idx] = 1
			  idx += 1
			}
		}
		
		// Reset the best location
		bestLocation = nil
		
		var score = 1.0
		var binMax: Int = pattern.len + textLength
		var lastBitArr = [Int]()
		
		let textCount = text.count
		
		// Magic begins now
		for i in 0..<pattern.len {
			
			// Scan for the best match; each iteration allows for one more error.
			// Run a binary search to determine how far from the match location we can stray at this error level.
			var binMin = 0
			var binMid = binMax
			
			while binMin < binMid {
				if Utilities.calculateScore(pattern.len, e: i, x: location, loc: location + binMid, distance: distance) <= threshold {
					binMin = binMid
				} else {
					binMax = binMid
				}
				binMid = ((binMax - binMin) / 2) + binMin
			}
			
			// Use the result from this iteration as the maximum for the next.
			binMax = binMid
			var start = max(1, location - binMid + 1)
			let finish = min(location + binMid, textLength) + pattern.len
			
			// Initialize the bit array
			var bitArr = [Int](repeating: 0, count: finish + 2)
			bitArr[finish + 1] = (1 << i) - 1
			
			if start > finish {
				continue
			}
			
			var currentLocationIndex: String.Index? = nil

			for j in (start...finish).reversed() {
				let currentLocation = j - 1
				
				// Need to check for `nil` case, since `patternAlphabet` is a sparse hash
				let charMatch: Int = {
					if currentLocation < textCount {
						currentLocationIndex = currentLocationIndex.map{text.index(before: $0)} ?? text.index(text.startIndex, offsetBy: currentLocation)
						let char = text[currentLocationIndex!]
						if let result = pattern.alphabet[char] {
							return result
						}
					}
					return 0
				}()
				
				// A match is found
				if charMatch != 0 {
					matchMaskArr[currentLocation] = 1
				}
				
				// First pass: exact match
				bitArr[j] = ((bitArr[j + 1] << 1) | 1) & charMatch
				
				// Subsequent passes: fuzzy match
				if i > 0 {
					bitArr[j] |= (((lastBitArr[j + 1] | lastBitArr[j]) << 1) | 1) | lastBitArr[j + 1]
				}
				
				if (bitArr[j] & pattern.mask) != 0 {
					score = Utilities.calculateScore(pattern.len, e: i, x: location, loc: currentLocation, distance: distance)
					
					// This match will almost certainly be better than any existing match. But check anyway.
					if score <= threshold {
						// Indeed it is
						threshold = score
						bestLocation = currentLocation

						guard let bestLocation = bestLocation else {
							break
						}
						
						if bestLocation > location  {
							// When passing `bestLocation`, don't exceed our current distance from the expected `location`.
							start = max(1, 2 * location - bestLocation)
						} else {
							// Already passed `location`. No point in continuing.
							break
						}
					}
				}
			}
			
			// No hope for a better match at greater error levels
			if Utilities.calculateScore(pattern.len, e: i + 1, x: location, loc: location, distance: distance) > threshold {
				break
			}
			
			lastBitArr = bitArr
		}
		
		let ranges = Utilities.findRanges(matchMaskArr)

		return .init(score: score, ranges: ranges.map { originalString.range(from: $0) })
	}
}

extension Fuse {
	/// Searches for a text pattern in a given string.
	///
	///     let fuse = Fuse()
	///     fuse.search("some text", in: "some string")
	///
	/// **Note**: if the same text needs to be searched across many strings, consider creating the pattern once via `createPattern`, and then use the other `search` function. This will improve performance, as the pattern object would only be created once, and re-used across every search call:
	///
	///     let fuse = Fuse()
	///     let pattern = fuse.createPattern(from: "some text")
	///     fuse.search(pattern, in: "some string")
	///     fuse.search(pattern, in: "another string")
	///     fuse.search(pattern, in: "yet another string")
	///
	/// - Parameters:
	///   - text: the text string to search for.
	///   - aString: The string in which to search for the pattern
	/// - Returns: A tuple containing a `score` between `0.0` (exact match) and `1` (not a match), and `ranges` of the matched characters.
	public func search(_ text: String, in aString: String) -> ResultItem? {
		return self.search(self.createPattern(from: text), in: aString)
	}
	
	/// Searches for a text pattern in an array of srings
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - aList: The list of string in which to search
	/// - Returns: A tuple containing the `item` in which the match is found, the `score`, and the `ranges` of the matched characters
	public func search<S: Sequence>(_ text: String, in list: S, maxResults: Int? = nil) async throws -> [StringSearchResult] where S.Element == String {
		let pattern = self.createPattern(from: text)
		
		var items = [StringSearchResult]()
		
		for (index, item) in list.enumerated() {
			try Task.checkCancellation()
			if let result = self.search(pattern, in: item) {
				items.append(.init(string: item, index: index, result: result))
			}
		}
		
		let sorted = items.sorted { $0.result.score < $1.result.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}
	
	/// Searches for a text pattern in an array of `Fuseable` objects.
	///
	/// Each `FuseSearchable` object contains a `properties` accessor which returns `FuseProperty` array. Each `FuseProperty` is a tuple containing a `key` (the value of the property which should be included in the search), and a `weight` (how much "weight" to assign to the score)
	///
	/// ## Example
	///
	/// Ensure the object conforms to `Fuseable`:
	///
	///     struct Book: Fuseable {
	///			var author: String
	///			var title: String
	///
	///			var fuseProperties: [String: FuseProperty] {
	///				return [
	///					"title": .init(value: title, weight: 0.3),
	///					"author": .init(value: author, weight: 0.7),
	///				]
	///			}
	///		}
	///
	/// Searching:
	///
	///     let books: [Book] = [
	///         Book(author: "John X", title: "Old Man's War fiction"),
	///         Book(author: "P.D. Mans", title: "Right Ho Jeeves")
	///     ]
	///
	///     let fuse = Fuse()
	///     let results = fuse.search("Man", in: books)
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - aList: The list of `Fuseable` objects in which to search
	/// - Returns: A list of `CollectionResult` objects
	public func search<T: Fuseable>(_ text: String, in list: [T], maxResults: Int? = nil) async throws -> [FusableSearchResult<T>] {
		try Task.checkCancellation()
		let pattern = self.createPattern(from: text)
		
		var collectionResult = [FusableSearchResult<T>]()
		
		for item in list {
			try Task.checkCancellation()
			var scores = [Double]()
			var totalScore = 0.0
			
			var propertyResults = [String: ResultItem]()
			
			for (key, property) in item.fuseProperties {
				if let result = self.search(pattern, in: property.value) {
					let weight = property.weight == 1 ? 1 : 1 - property.weight
					let score = (result.score == 0 && weight == 1 ? 0.001 : result.score) * weight
					totalScore += score
					
					scores.append(score)
					
					propertyResults[key] = .init(score: score, ranges: result.ranges)
				}
			}
			
			guard !scores.isEmpty else {
				continue
			}
			
			collectionResult.append(FusableSearchResult(
				item: item,
				score: totalScore / Double(scores.count),
				resultsByKey: propertyResults
			))
		}
		let sorted = collectionResult.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

}

// MARK: - FuseIndex Support

extension Fuse {

	// MARK: Creating Indexes

	/// Creates a preprocessed index from an array of strings for faster repeated searches.
	///
	/// Use this when you need to search the same dataset multiple times with different queries.
	/// The index pre-computes lowercased text, avoiding redundant work on each search.
	///
	/// ## Example
	///
	///     let fuse = Fuse()
	///     let names = ["John Smith", "Jane Doe", "Bob Wilson"]
	///     let index = fuse.createIndex(from: names)
	///
	///     // Fast repeated searches - no re-lowercasing needed
	///     let results1 = try await fuse.search("john", in: index)
	///     let results2 = try await fuse.search("wilson", in: index)
	///
	/// - Parameter list: The array of strings to index
	/// - Returns: A `FuseIndex` that can be used for repeated searches
	public func createIndex(from list: [String]) -> FuseIndex<String> {
		let indexedItems = list.enumerated().map { index, item in
			FuseIndex<String>.IndexedItem(
				item: item,
				index: index,
				properties: ["": (original: item, normalized: isCaseSensitive ? item : item.lowercased(), weight: 1.0)]
			)
		}
		return FuseIndex(items: indexedItems, isCaseSensitive: isCaseSensitive)
	}

	/// Creates a preprocessed index from an array of `Fuseable` objects for faster repeated searches.
	///
	/// Use this when you need to search the same dataset multiple times with different queries.
	/// The index pre-computes lowercased text and caches property metadata.
	///
	/// ## Example
	///
	///     let fuse = Fuse()
	///     let books: [Book] = [
	///         Book(author: "J.R.R. Tolkien", title: "The Lord of the Rings"),
	///         Book(author: "George Orwell", title: "1984")
	///     ]
	///     let index = fuse.createIndex(from: books)
	///
	///     // Fast repeated searches
	///     let results1 = try await fuse.search("tolkien", in: index)
	///     let results2 = try await fuse.search("orwell", in: index)
	///
	/// - Parameter list: The array of `Fuseable` objects to index
	/// - Returns: A `FuseIndex` that can be used for repeated searches
	public func createIndex<T: Fuseable>(from list: [T]) -> FuseIndex<T> {
		let indexedItems = list.enumerated().map { index, item in
			var properties = [String: (original: String, normalized: String, weight: Double)]()
			for (key, property) in item.fuseProperties {
				properties[key] = (
					original: property.value,
					normalized: isCaseSensitive ? property.value : property.value.lowercased(),
					weight: property.weight
				)
			}
			return FuseIndex<T>.IndexedItem(
				item: item,
				index: index,
				properties: properties
			)
		}
		return FuseIndex(items: indexedItems, isCaseSensitive: isCaseSensitive)
	}

	// MARK: Searching with Indexes

	/// Searches for a text pattern in a preprocessed string index.
	///
	/// This is faster than searching an array directly when performing multiple searches,
	/// as the index has pre-computed lowercased text.
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - index: The preprocessed index to search
	///   - maxResults: Optional limit on number of results returned
	/// - Returns: An array of `StringSearchResult` sorted by score (best matches first)
	public func search(_ text: String, in index: FuseIndex<String>, maxResults: Int? = nil) async throws -> [StringSearchResult] {
		guard index.isCaseSensitive == self.isCaseSensitive else {
			// Fall back to regular search if case sensitivity doesn't match
			return try await search(text, in: index.items.map { $0.item }, maxResults: maxResults)
		}

		let pattern = self.createPattern(from: text)

		var items = [StringSearchResult]()

		for indexedItem in index.items {
			try Task.checkCancellation()
			if let result = searchIndexed(pattern, in: indexedItem.properties[""]!) {
				items.append(.init(string: indexedItem.item, index: indexedItem.index, result: result))
			}
		}

		let sorted = items.sorted { $0.result.score < $1.result.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	/// Searches for a text pattern in a preprocessed `Fuseable` index.
	///
	/// This is faster than searching an array directly when performing multiple searches,
	/// as the index has pre-computed lowercased text and cached property metadata.
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - index: The preprocessed index to search
	///   - maxResults: Optional limit on number of results returned
	/// - Returns: An array of `FusableSearchResult` sorted by score (best matches first)
	public func search<T: Fuseable>(_ text: String, in index: FuseIndex<T>, maxResults: Int? = nil) async throws -> [FusableSearchResult<T>] {
		guard index.isCaseSensitive == self.isCaseSensitive else {
			// Fall back to regular search if case sensitivity doesn't match
			return try await search(text, in: index.items.map { $0.item }, maxResults: maxResults)
		}

		try Task.checkCancellation()
		let pattern = self.createPattern(from: text)

		var collectionResult = [FusableSearchResult<T>]()

		for indexedItem in index.items {
			try Task.checkCancellation()
			var scores = [Double]()
			var totalScore = 0.0
			var propertyResults = [String: ResultItem]()

			for (key, property) in indexedItem.properties {
				if let result = searchIndexed(pattern, in: property) {
					let weight = property.weight == 1 ? 1 : 1 - property.weight
					let score = (result.score == 0 && weight == 1 ? 0.001 : result.score) * weight
					totalScore += score
					scores.append(score)
					propertyResults[key] = .init(score: score, ranges: result.ranges)
				}
			}

			guard !scores.isEmpty else {
				continue
			}

			collectionResult.append(FusableSearchResult(
				item: indexedItem.item,
				score: totalScore / Double(scores.count),
				resultsByKey: propertyResults
			))
		}

		let sorted = collectionResult.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	// MARK: Private Helpers

	/// Searches using pre-normalized indexed property data
	private func searchIndexed(_ pattern: Pattern?, in property: (original: String, normalized: String, weight: Double)) -> ResultItem? {
		guard let pattern = pattern else {
			return nil
		}

		if tokenize {
			let wordPatterns = pattern.text.split(separator: " ").compactMap { createPattern(from: String($0)) }
			let fullPatternResult = _search(pattern, in: property.original, normalizedText: property.normalized)

			let results = wordPatterns.reduce(into: fullPatternResult) { totalResult, wordPattern in
				let result = _search(wordPattern, in: property.original, normalizedText: property.normalized)
				totalResult = .init(score: totalResult.score + result.score, ranges: totalResult.ranges + result.ranges)
			}

			let averagedResult = ResultItem(
				score: results.score / Double(wordPatterns.count + 1),
				ranges: Array(Set(results.ranges))
			)
			return averagedResult.score == 1 ? nil : averagedResult
		} else {
			let result = _search(pattern, in: property.original, normalizedText: property.normalized)
			return result.score == 1 ? nil : result
		}
	}
}
