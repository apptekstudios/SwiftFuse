

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
	private let ignoreLocation: Bool

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

	/// Configuration for parallel search operations
	internal struct SearchConfig: Sendable {
		let location: Int
		let distance: Int
		let threshold: Double
		let tokenize: Bool
		let ignoreLocation: Bool
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
	///   - ignoreLocation: When true, search will ignore where in the string the pattern is expected to be found. Defaults to `false`
	public init(
		data: [String],
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		maxPatternLength: Int = 32,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false,
		ignoreLocation: Bool = false
	) where T == String {
		self.location = location
		self.distance = distance
		self.threshold = threshold
		self.maxPatternLength = maxPatternLength
		self.isCaseSensitive = isCaseSensitive
		self.tokenize = tokenize
		self.ignoreLocation = ignoreLocation

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
	///   - ignoreLocation: When true, search will ignore where in the string the pattern is expected to be found. Defaults to `false`
	public init(
		data: [T],
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		maxPatternLength: Int = 32,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false,
		ignoreLocation: Bool = false
	) where T: Fuseable {
		self.location = location
		self.distance = distance
		self.threshold = threshold
		self.maxPatternLength = maxPatternLength
		self.isCaseSensitive = isCaseSensitive
		self.tokenize = tokenize
		self.ignoreLocation = ignoreLocation

		// Build index asynchronously in background
		Task { [weak self] in
			await self?.buildFuseableIndex(from: data)
		}
	}

	// MARK: - Background Index Building

	private func buildStringIndex(from data: [String]) {
		let indexedItems = data.enumerated().map { idx, item in
			let normalized = isCaseSensitive ? item : item.lowercased()
			let characters = Array(normalized)
			return FuseIndex<String>.IndexedItem(
				item: item,
				index: idx,
				properties: ["": FuseIndex<String>.IndexedProperty(
					original: item,
					normalized: normalized,
					characters: characters,
					characterSet: Set(characters),
					weight: 1.0,
					length: characters.count
				)]
			)
		}
		self.index = FuseIndex(items: indexedItems, isCaseSensitive: isCaseSensitive) as? FuseIndex<T>
		markIndexReady()
	}

	private func buildFuseableIndex<U: Fuseable>(from data: [U]) where T == U {
		let indexedItems = data.enumerated().map { idx, item in
			var properties = [String: FuseIndex<T>.IndexedProperty]()
			for (key, property) in item.fuseProperties {
				let normalized = isCaseSensitive ? property.value : property.value.lowercased()
				let characters = Array(normalized)
				properties[key] = FuseIndex<T>.IndexedProperty(
					original: property.value,
					normalized: normalized,
					characters: characters,
					characterSet: Set(characters),
					weight: property.weight,
					length: characters.count
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

	/// Minimum items to trigger parallel search (below this, sequential is faster)
	private static let parallelThreshold = 100

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
		guard let pattern = createPattern(from: text) else { return [] }

		let items: [SearchResult]

		// Use parallel search for large datasets
		if index.items.count >= Self.parallelThreshold {
			items = try await searchParallel(pattern: pattern, in: index)
		} else {
			items = searchSequential(pattern: pattern, in: index)
		}

		let sorted = items.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	/// Sequential search for small datasets
	private func searchSequential(pattern: Pattern, in index: FuseIndex<T>) -> [SearchResult] where T == String {
		var items = [SearchResult]()
		for indexedItem in index.items {
			if let result = searchIndexed(pattern, in: indexedItem.properties[""]!) {
				items.append(SearchResult(
					item: indexedItem.item,
					index: indexedItem.index,
					score: result.score,
					results: ["": result]
				))
			}
		}
		return items
	}

	/// Parallel search for large datasets using TaskGroup
	private func searchParallel(pattern: Pattern, in index: FuseIndex<T>) async throws -> [SearchResult] where T == String {
		// Capture config for use in tasks
		let config = SearchConfig(
			location: location,
			distance: distance,
			threshold: threshold,
			tokenize: tokenize,
			ignoreLocation: ignoreLocation
		)

		return try await withThrowingTaskGroup(of: SearchResult?.self) { group in
			for indexedItem in index.items {
				let property = indexedItem.properties[""]!
				group.addTask {
					try Task.checkCancellation()
					if let result = Self.searchProperty(pattern: pattern, property: property, config: config) {
						return SearchResult(
							item: indexedItem.item,
							index: indexedItem.index,
							score: result.score,
							results: ["": result]
						)
					}
					return nil
				}
			}

			var results = [SearchResult]()
			for try await result in group {
				if let result = result {
					results.append(result)
				}
			}
			return results
		}
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
		guard let pattern = createPattern(from: text) else { return [] }

		let collectionResult: [SearchResult]

		// Use parallel search for large datasets
		if index.items.count >= Self.parallelThreshold {
			collectionResult = try await searchFuseableParallel(pattern: pattern, in: index)
		} else {
			collectionResult = searchFuseableSequential(pattern: pattern, in: index)
		}

		let sorted = collectionResult.sorted { $0.score < $1.score }
		return maxResults.map { Array(sorted.prefix($0)) } ?? sorted
	}

	/// Sequential search for Fuseable items
	private func searchFuseableSequential(pattern: Pattern, in index: FuseIndex<T>) -> [SearchResult] where T: Fuseable {
		var collectionResult = [SearchResult]()

		for indexedItem in index.items {
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

		return collectionResult
	}

	/// Parallel search for Fuseable items using TaskGroup
	private func searchFuseableParallel(pattern: Pattern, in index: FuseIndex<T>) async throws -> [SearchResult] where T: Fuseable {
		// Capture config for use in tasks
		let config = SearchConfig(
			location: location,
			distance: distance,
			threshold: threshold,
			tokenize: tokenize,
			ignoreLocation: ignoreLocation
		)

		return try await withThrowingTaskGroup(of: SearchResult?.self) { group in
			for indexedItem in index.items {
				group.addTask {
					try Task.checkCancellation()
					var scores = [Double]()
					var totalScore = 0.0
					var propertyResults = [String: ResultItem]()

					for (key, property) in indexedItem.properties {
						if let result = Self.searchProperty(pattern: pattern, property: property, config: config) {
							let weight = property.weight == 1 ? 1 : 1 - property.weight
							let score = (result.score == 0 && weight == 1 ? 0.001 : result.score) * weight
							totalScore += score
							scores.append(score)
							propertyResults[key] = ResultItem(score: score, ranges: result.ranges)
						}
					}

					guard !scores.isEmpty else {
						return nil
					}

					return SearchResult(
						item: indexedItem.item,
						index: indexedItem.index,
						score: totalScore / Double(scores.count),
						results: propertyResults
					)
				}
			}

			var results = [SearchResult]()
			for try await result in group {
				if let result = result {
					results.append(result)
				}
			}
			return results
		}
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
	private func searchIndexed<U>(_ pattern: Pattern?, in property: FuseIndex<U>.IndexedProperty) -> ResultItem? {
		guard let pattern = pattern else {
			return nil
		}

		// Pre-filter: check if text contains enough pattern characters to possibly match
		// If fewer than half the pattern characters exist in the text, skip expensive search
		let patternChars = Set(pattern.text)
		let matchingChars = patternChars.intersection(property.characterSet)
		let minRequiredChars = max(1, patternChars.count / 2)
		if matchingChars.count < minRequiredChars {
			return nil
		}

		if tokenize {
			let wordPatterns = pattern.text.split(separator: " ").compactMap { createPattern(from: String($0)) }
			let fullPatternResult = _search(pattern, in: property.original, characters: property.characters, textLength: property.length)

			let results = wordPatterns.reduce(into: fullPatternResult) { totalResult, wordPattern in
				let result = _search(wordPattern, in: property.original, characters: property.characters, textLength: property.length)
				totalResult = ResultItem(score: totalResult.score + result.score, ranges: totalResult.ranges + result.ranges)
			}

			let averagedResult = ResultItem(
				score: results.score / Double(wordPatterns.count + 1),
				ranges: Array(Set(results.ranges))
			)
			return averagedResult.score == 1 ? nil : averagedResult
		} else {
			let result = _search(pattern, in: property.original, characters: property.characters, textLength: property.length)
			return result.score == 1 ? nil : result
		}
	}

	/// Core Bitap algorithm implementation with O(1) character access
	private func _search(_ pattern: Pattern, in originalString: String, characters: [Character], textLength: Int) -> ResultItem {

		// Create normalized string for substring search (used only for exact match finding)
		let normalizedText = String(characters)

		// Exact match
		if pattern.text == normalizedText {
			return ResultItem(score: 0, ranges: [originalString.startIndex ..< originalString.endIndex])
		}

		let location = self.location
		let distance = self.distance
		var threshold = self.threshold

		var bestLocation: Int? = {
			if let index = normalizedText.index(of: pattern.text, startingFrom: location) {
				return normalizedText.distance(from: normalizedText.startIndex, to: index)
			}
			return nil
		}()

		// A mask of the matches
		var matchMaskArr = [Int](repeating: 0, count: textLength)

		// Get all exact matches for speed up
		var index = normalizedText.index(of: pattern.text, startingFrom: bestLocation)
		while index != nil {
			let i = normalizedText.distance(from: normalizedText.startIndex, to: index!)
			let score = Utilities.calculateScore(pattern.len, e: 0, x: i, loc: location, distance: distance, ignoreLocation: ignoreLocation)
			threshold = min(threshold, score)
			bestLocation = i + pattern.len
			index = normalizedText.index(of: pattern.text, startingFrom: bestLocation)

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

		// Bitap algorithm
		for i in 0..<pattern.len {
			var binMin = 0
			var binMid = binMax

			while binMin < binMid {
				if Utilities.calculateScore(pattern.len, e: i, x: location, loc: location + binMid, distance: distance, ignoreLocation: ignoreLocation) <= threshold {
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

			// O(1) character access using array instead of String.Index traversal
			for j in (start...finish).reversed() {
				let currentLocation = j - 1

				let charMatch: Int = {
					if currentLocation < textLength {
						let char = characters[currentLocation]
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
					score = Utilities.calculateScore(pattern.len, e: i, x: location, loc: currentLocation, distance: distance, ignoreLocation: ignoreLocation)

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

			if Utilities.calculateScore(pattern.len, e: i + 1, x: location, loc: location, distance: distance, ignoreLocation: ignoreLocation) > threshold {
				break
			}

			lastBitArr = bitArr
		}

		let ranges = Utilities.findRanges(matchMaskArr)

		return ResultItem(score: score, ranges: ranges.map { originalString.range(from: $0) })
	}

	// MARK: - Nonisolated Search for Parallel Execution

	/// Static search method for parallel execution (nonisolated to run in TaskGroup)
	nonisolated static func searchProperty<U>(
		pattern: Pattern,
		property: FuseIndex<U>.IndexedProperty,
		config: SearchConfig
	) -> ResultItem? {
		// Pre-filter: check if text contains enough pattern characters to possibly match
		let patternChars = Set(pattern.text)
		let matchingChars = patternChars.intersection(property.characterSet)
		let minRequiredChars = max(1, patternChars.count / 2)
		if matchingChars.count < minRequiredChars {
			return nil
		}

		if config.tokenize {
			let wordPatterns = pattern.text.split(separator: " ").compactMap { word -> Pattern? in
				let patternStr = String(config.ignoreLocation ? word : word.lowercased()).prefix(Int.bitWidth - 1)
				let len = patternStr.count
				guard len > 0 else { return nil }
				return (
					text: String(patternStr),
					len: len,
					mask: 1 << (len - 1),
					alphabet: Utilities.calculatePatternAlphabet(String(patternStr))
				)
			}
			let fullPatternResult = searchStatic(pattern, in: property.original, characters: property.characters, textLength: property.length, config: config)

			let results = wordPatterns.reduce(into: fullPatternResult) { totalResult, wordPattern in
				let result = searchStatic(wordPattern, in: property.original, characters: property.characters, textLength: property.length, config: config)
				totalResult = ResultItem(score: totalResult.score + result.score, ranges: totalResult.ranges + result.ranges)
			}

			let averagedResult = ResultItem(
				score: results.score / Double(wordPatterns.count + 1),
				ranges: Array(Set(results.ranges))
			)
			return averagedResult.score == 1 ? nil : averagedResult
		} else {
			let result = searchStatic(pattern, in: property.original, characters: property.characters, textLength: property.length, config: config)
			return result.score == 1 ? nil : result
		}
	}

	/// Static Bitap algorithm implementation for parallel execution
	nonisolated private static func searchStatic(_ pattern: Pattern, in originalString: String, characters: [Character], textLength: Int, config: SearchConfig) -> ResultItem {
		// Create normalized string for substring search
		let normalizedText = String(characters)

		// Exact match
		if pattern.text == normalizedText {
			return ResultItem(score: 0, ranges: [originalString.startIndex ..< originalString.endIndex])
		}

		let location = config.location
		let distance = config.distance
		var threshold = config.threshold
		let ignoreLocation = config.ignoreLocation

		var bestLocation: Int? = {
			if let index = normalizedText.index(of: pattern.text, startingFrom: location) {
				return normalizedText.distance(from: normalizedText.startIndex, to: index)
			}
			return nil
		}()

		var matchMaskArr = [Int](repeating: 0, count: textLength)

		var index = normalizedText.index(of: pattern.text, startingFrom: bestLocation)
		while index != nil {
			let i = normalizedText.distance(from: normalizedText.startIndex, to: index!)
			let score = Utilities.calculateScore(pattern.len, e: 0, x: i, loc: location, distance: distance, ignoreLocation: ignoreLocation)
			threshold = min(threshold, score)
			bestLocation = i + pattern.len
			index = normalizedText.index(of: pattern.text, startingFrom: bestLocation)

			var idx = 0
			while idx < pattern.len {
				matchMaskArr[i + idx] = 1
				idx += 1
			}
		}

		bestLocation = nil

		var score = 1.0
		var binMax: Int = pattern.len + textLength
		var lastBitArr = [Int]()

		for i in 0..<pattern.len {
			var binMin = 0
			var binMid = binMax

			while binMin < binMid {
				if Utilities.calculateScore(pattern.len, e: i, x: location, loc: location + binMid, distance: distance, ignoreLocation: ignoreLocation) <= threshold {
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

			for j in (start...finish).reversed() {
				let currentLocation = j - 1

				let charMatch: Int = {
					if currentLocation < textLength {
						let char = characters[currentLocation]
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
					score = Utilities.calculateScore(pattern.len, e: i, x: location, loc: currentLocation, distance: distance, ignoreLocation: ignoreLocation)

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

			if Utilities.calculateScore(pattern.len, e: i + 1, x: location, loc: location, distance: distance, ignoreLocation: ignoreLocation) > threshold {
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
	///   - ignoreLocation: When true, score is based only on match accuracy. Defaults to `false`
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public static func search(
		_ text: String,
		in data: [String],
		maxResults: Int? = nil,
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false,
		ignoreLocation: Bool = false
	) async throws -> [Fuse<String>.SearchResult] {
		let fuse = Fuse<String>(
			data: data,
			location: location,
			distance: distance,
			threshold: threshold,
			isCaseSensitive: isCaseSensitive,
			tokenize: tokenize,
			ignoreLocation: ignoreLocation
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
	///   - ignoreLocation: When true, score is based only on match accuracy. Defaults to `false`
	/// - Returns: An array of `SearchResult` sorted by score (best matches first)
	public static func search<U: Fuseable & Sendable>(
		_ text: String,
		in data: [U],
		maxResults: Int? = nil,
		location: Int = 0,
		distance: Int = 100,
		threshold: Double = 0.6,
		isCaseSensitive: Bool = false,
		tokenize: Bool = false,
		ignoreLocation: Bool = false
	) async throws -> [Fuse<U>.SearchResult] {
		let fuse = Fuse<U>(
			data: data,
			location: location,
			distance: distance,
			threshold: threshold,
			isCaseSensitive: isCaseSensitive,
			tokenize: tokenize,
			ignoreLocation: ignoreLocation
		)
		return try await fuse.search(text, maxResults: maxResults)
	}
}
