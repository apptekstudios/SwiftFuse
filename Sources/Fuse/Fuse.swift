

import Foundation

@globalActor
public actor FuseActor {
	public static let shared = FuseActor()
}

/// A fuzzy search engine using the Bitap algorithm.
///
/// ## Creating an Instance with Data (Recommended for repeated searches)
///
/// When you need to search the same dataset multiple times, create a `Fuse` instance with your data.
/// The index is built asynchronously in the background - init returns immediately:
///
///     let fuse = Fuse(data: books)  // Returns immediately, indexing in background
///     let results1 = try await fuse.search("tolkien")  // Waits for index if needed
///     let results2 = try await fuse.search("orwell")   // Index ready, instant
///
/// ## One-Time Searches (Static Method)
///
/// For single searches where you don't need to reuse the index:
///
///     let results = try await Fuse.search("tolkien", in: books)
///
@FuseActor
public class Fuse<T: Sendable>: Sendable {
	private let location: Int
	private let distance: Int
	private let threshold: Double
	private let maxPatternLength: Int
	private let isCaseSensitive: Bool
	private let tokenize: Bool

	/// The preprocessed index for fast searches (nil until indexing completes)
	private var index: FuseIndex<T>?

	/// Continuations waiting for the index to be ready
	private var waiters: [CheckedContinuation<Void, Never>] = []

	/// Whether indexing has completed
	private var isIndexReady: Bool = false

	public typealias Pattern = (text: String, len: Int, mask: Int, alphabet: [Character: Int])

	public struct SearchResult: Sendable {
		public var item: T
		public var index: Int
		public var score: Double
		public var results: [String: ResultItem]
	}

	public struct ResultItem: Sendable {
		public var score: Double
		public var ranges: [Range<String.Index>]
	}

	// MARK: - Initialization

	/// Creates a new `Fuse` instance with a dataset of strings.
	///
	/// The index is built asynchronously in the background. Init returns immediately.
	/// Search calls will automatically wait for the index to be ready.
	///
	/// - Parameters:
	///   - data: The array of strings to search
	///   - location: Approximately where in the text is the pattern expected to be found. Defaults to `0`
	///   - distance: Determines how close the match must be to the fuzzy `location`. Defaults to `100`
	///   - threshold: At what point does the match algorithm give up. A threshold of `0.0` requires a perfect match, `1.0` matches anything. Defaults to `0.6`
	///   - maxPatternLength: The maximum valid pattern length. Defaults to `32`
	///   - isCaseSensitive: Indicates whether comparisons should be case sensitive. Defaults to `false`
	///   - tokenize: When true, searches individual words and the full string. Defaults to `false`
	public init(
		data: [String],
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		maxPatternLength: Int = 32,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false
	) where T == String {
		self.location = location
		self.distance = distance
		self.threshold = threshold
		self.maxPatternLength = maxPatternLength
		self.isCaseSensitive = isCaseSensitive
		self.tokenize = tokenize

		// Build index asynchronously in background
		Task { [weak self] in
			await self?.buildStringIndex(from: data)
		}
	}

	/// Creates a new `Fuse` instance with a dataset of `Fuseable` objects.
	///
	/// The index is built asynchronously in the background. Init returns immediately.
	/// Search calls will automatically wait for the index to be ready.
	///
	/// - Parameters:
	///   - data: The array of `Fuseable` objects to search
	///   - location: Approximately where in the text is the pattern expected to be found. Defaults to `0`
	///   - distance: Determines how close the match must be to the fuzzy `location`. Defaults to `100`
	///   - threshold: At what point does the match algorithm give up. A threshold of `0.0` requires a perfect match, `1.0` matches anything. Defaults to `0.6`
	///   - maxPatternLength: The maximum valid pattern length. Defaults to `32`
	///   - isCaseSensitive: Indicates whether comparisons should be case sensitive. Defaults to `false`
	///   - tokenize: When true, searches individual words and the full string. Defaults to `false`
	public init(
		data: [T],
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		maxPatternLength: Int = 32,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false
	) where T: Fuseable {
		self.location = location
		self.distance = distance
		self.threshold = threshold
		self.maxPatternLength = maxPatternLength
		self.isCaseSensitive = isCaseSensitive
		self.tokenize = tokenize

		// Build index asynchronously in background
		Task { [weak self] in
			await self?.buildFuseableIndex(from: data)
		}
	}

	// MARK: - Background Index Building

	private func buildStringIndex(from data: [String]) {
		let indexedItems = data.enumerated().map { idx, item in
			FuseIndex<String>.IndexedItem(
				item: item,
				index: idx,
				properties: ["": (original: item, normalized: isCaseSensitive ? item : item.lowercased(), weight: 1.0)]
			)
		}
		self.index = FuseIndex(items: indexedItems, isCaseSensitive: isCaseSensitive) as? FuseIndex<T>
		markIndexReady()
	}

	private func buildFuseableIndex<U: Fuseable>(from data: [U]) where T == U {
		let indexedItems = data.enumerated().map { idx, item in
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
				index: idx,
				properties: properties
			)
		}
		self.index = FuseIndex(items: indexedItems, isCaseSensitive: isCaseSensitive)
		markIndexReady()
	}

	private func markIndexReady() {
		isIndexReady = true
		// Resume all waiting continuations
		for waiter in waiters {
			waiter.resume()
		}
		waiters.removeAll()
	}

	/// Waits for the index to be ready
	private func awaitIndexReady() async {
		if isIndexReady { return }

		await withCheckedContinuation { continuation in
			if isIndexReady {
				continuation.resume()
			} else {
				waiters.append(continuation)
			}
		}
	}

	// MARK: - Instance Search Methods

	/// Searches for a pattern in the indexed dataset.
	///
	/// If the index is still being built, this method will wait until it's ready.
	///
	///     let fuse = Fuse(data: books)  // Returns immediately
	///     let results = try await fuse.search("tolkien")  // Waits for index if needed
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - maxResults: Optional limit on number of results returned
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public func search(_ text: String, maxResults: Int? = nil) async throws -> [SearchResult] where T == String {
		await awaitIndexReady()

		guard let index = index else { return [] }

		let pattern = createPattern(from: text)
		var items = [SearchResult]()

		for indexedItem in index.items {
			try Task.checkCancellation()
			if let result = searchIndexed(pattern, in: indexedItem.properties[""]!) {
				items.append(SearchResult(
					item: indexedItem.item,
					index: indexedItem.index,
					score: result.score,
					results: ["": result]
				))
			}
		}

		let sorted = items.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	/// Searches for a pattern in the indexed dataset.
	///
	/// If the index is still being built, this method will wait until it's ready.
	///
	///     let fuse = Fuse(data: books)  // Returns immediately
	///     let results = try await fuse.search("tolkien")  // Waits for index if needed
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - maxResults: Optional limit on number of results returned
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public func search(_ text: String, maxResults: Int? = nil) async throws -> [SearchResult] where T: Fuseable {
		await awaitIndexReady()

		guard let index = index else { return [] }

		try Task.checkCancellation()
		let pattern = createPattern(from: text)

		var collectionResult = [SearchResult]()

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
					propertyResults[key] = ResultItem(score: score, ranges: result.ranges)
				}
			}

			guard !scores.isEmpty else {
				continue
			}

			collectionResult.append(SearchResult(
				item: indexedItem.item,
				index: indexedItem.index,
				score: totalScore / Double(scores.count),
				results: propertyResults
			))
		}

		let sorted = collectionResult.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	// MARK: - Pattern Creation

	/// Creates a pattern tuple for searching.
	///
	/// - Parameter aString: A string from which to create the pattern tuple
	/// - Returns: A tuple containing pattern metadata
	public func createPattern(from aString: String) -> Pattern? {
		let pattern = String((isCaseSensitive ? aString : aString.lowercased()).prefix(Int.bitWidth - 1))
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

	// MARK: - Private Search Implementation

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
				totalResult = ResultItem(score: totalResult.score + result.score, ranges: totalResult.ranges + result.ranges)
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

	/// Core Bitap algorithm implementation
	private func _search(_ pattern: Pattern, in originalString: String, normalizedText text: String) -> ResultItem {

		let textLength = text.count

		// Exact match
		if pattern.text == text {
			return ResultItem(score: 0, ranges: [text.startIndex ..< text.endIndex])
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

		// A mask of the matches
		var matchMaskArr = [Int](repeating: 0, count: textLength)

		// Get all exact matches for speed up
		var index = text.index(of: pattern.text, startingFrom: bestLocation)
		while index != nil {
			let i = text.distance(from: text.startIndex, to: index!)
			let score = Utilities.calculateScore(pattern.len, e: 0, x: i, loc: location, distance: distance)
			threshold = min(threshold, score)
			bestLocation = i + pattern.len
			index = text.index(of: pattern.text, startingFrom: bestLocation)

			var idx = 0
			while idx < pattern.len {
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

		// Bitap algorithm
		for i in 0..<pattern.len {
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

			binMax = binMid
			var start = max(1, location - binMid + 1)
			let finish = min(location + binMid, textLength) + pattern.len

			var bitArr = [Int](repeating: 0, count: finish + 2)
			bitArr[finish + 1] = (1 << i) - 1

			if start > finish {
				continue
			}

			var currentLocationIndex: String.Index? = nil

			for j in (start...finish).reversed() {
				let currentLocation = j - 1

				let charMatch: Int = {
					if currentLocation < textCount {
						currentLocationIndex = currentLocationIndex.map { text.index(before: $0) } ?? text.index(text.startIndex, offsetBy: currentLocation)
						let char = text[currentLocationIndex!]
						if let result = pattern.alphabet[char] {
							return result
						}
					}
					return 0
				}()

				if charMatch != 0 {
					matchMaskArr[currentLocation] = 1
				}

				bitArr[j] = ((bitArr[j + 1] << 1) | 1) & charMatch

				if i > 0 {
					bitArr[j] |= (((lastBitArr[j + 1] | lastBitArr[j]) << 1) | 1) | lastBitArr[j + 1]
				}

				if (bitArr[j] & pattern.mask) != 0 {
					score = Utilities.calculateScore(pattern.len, e: i, x: location, loc: currentLocation, distance: distance)

					if score <= threshold {
						threshold = score
						bestLocation = currentLocation

						guard let bestLocation = bestLocation else {
							break
						}

						if bestLocation > location {
							start = max(1, 2 * location - bestLocation)
						} else {
							break
						}
					}
				}
			}

			if Utilities.calculateScore(pattern.len, e: i + 1, x: location, loc: location, distance: distance) > threshold {
				break
			}

			lastBitArr = bitArr
		}

		let ranges = Utilities.findRanges(matchMaskArr)

		return ResultItem(score: score, ranges: ranges.map { originalString.range(from: $0) })
	}
}

// MARK: - Static Search Methods

extension Fuse {

	/// Performs a one-time fuzzy search on an array of strings.
	///
	/// Use this for single searches where you don't need to reuse the index.
	/// For repeated searches on the same data, create a `Fuse` instance instead.
	///
	///     let results = try await Fuse.search("john", in: names)
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - data: The array of strings to search
	///   - maxResults: Optional limit on number of results returned
	///   - location: Approximately where in the text is the pattern expected to be found. Defaults to `0`
	///   - distance: Determines how close the match must be to the fuzzy `location`. Defaults to `100`
	///   - threshold: At what point does the match algorithm give up. Defaults to `0.6`
	///   - isCaseSensitive: Indicates whether comparisons should be case sensitive. Defaults to `false`
	///   - tokenize: When true, searches individual words and the full string. Defaults to `false`
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public static func search(
		_ text: String,
		in data: [String],
		maxResults: Int? = nil,
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false
	) async throws -> [Fuse<String>.SearchResult] {
		let fuse = Fuse<String>(
			data: data,
			location: location,
			distance: distance,
			threshold: threshold,
			isCaseSensitive: isCaseSensitive,
			tokenize: tokenize
		)
		return try await fuse.search(text, maxResults: maxResults)
	}

	/// Performs a one-time fuzzy search on an array of `Fuseable` objects.
	///
	/// Use this for single searches where you don't need to reuse the index.
	/// For repeated searches on the same data, create a `Fuse` instance instead.
	///
	///     let results = try await Fuse.search("tolkien", in: books)
	///
	/// - Parameters:
	///   - text: The pattern string to search for
	///   - data: The array of `Fuseable` objects to search
	///   - maxResults: Optional limit on number of results returned
	///   - location: Approximately where in the text is the pattern expected to be found. Defaults to `0`
	///   - distance: Determines how close the match must be to the fuzzy `location`. Defaults to `100`
	///   - threshold: At what point does the match algorithm give up. Defaults to `0.6`
	///   - isCaseSensitive: Indicates whether comparisons should be case sensitive. Defaults to `false`
	///   - tokenize: When true, searches individual words and the full string. Defaults to `false`
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public static func search<U: Fuseable & Sendable>(
		_ text: String,
		in data: [U],
		maxResults: Int? = nil,
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false
	) async throws -> [Fuse<U>.SearchResult] {
		let fuse = Fuse<U>(
			data: data,
			location: location,
			distance: distance,
			threshold: threshold,
			isCaseSensitive: isCaseSensitive,
			tokenize: tokenize
		)
		return try await fuse.search(text, maxResults: maxResults)
	}
}
