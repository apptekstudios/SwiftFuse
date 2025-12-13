import XCTest
@testable import Fuse

final class FuseTests: XCTestCase {

	// MARK: - Instance-based Search (with pre-indexed data)

	func testFuseableSearch() async throws {
		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves")
		]

		// Create Fuse instance - returns immediately, indexing happens in background
		let fuse = Fuse(data: books)

		// Search waits for index to be ready automatically
		let results = try await fuse.search("odmanfict")

		XCTAssertFalse(results.isEmpty)
		print("Found \(results.count) results for 'odmanfict'")

		for result in results {
			for (key, match) in result.results {
				switch key {
				case "author":
					print("MATCHED AUTHOR: \(result.item.author)")
					for range in match.ranges {
						print("  RANGE: \(result.item.author[range])")
					}
				case "title":
					print("MATCHED TITLE: \(result.item.title)")
					for range in match.ranges {
						print("  RANGE: \(result.item.title[range])")
					}
				default:
					break
				}
			}
		}
	}

	func testRepeatedSearches() async throws {
		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves"),
			Book(author: "J.R.R. Tolkien", title: "The Lord of the Rings"),
			Book(author: "George Orwell", title: "1984")
		]

		// Create once (non-blocking), search many times
		let fuse = Fuse(data: books)

		let queries = ["tolkien", "man", "orwell", "rings"]
		for query in queries {
			let results = try await fuse.search(query)
			print("Query '\(query)': found \(results.count) results")
			for result in results {
				print("  - \(result.item.title) by \(result.item.author) (score: \(result.score))")
			}
		}
	}

	func testStringSearch() async throws {
		let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

		// Create Fuse instance with string data (non-blocking)
		let fuse = Fuse(data: names)

		let results = try await fuse.search("john")
		XCTAssertEqual(results.count, 2) // "John Smith" and "Alice Johnson"

		print("Found \(results.count) matches for 'john'")
		for result in results {
			print("  - \(result.item) (score: \(result.score))")
		}
	}

	// MARK: - Static Search (one-time, no instance needed)

	func testStaticFuseableSearch() async throws {
		let books: [Book] = [
			Book(author: "J.R.R. Tolkien", title: "The Lord of the Rings"),
			Book(author: "George Orwell", title: "1984")
		]

		// One-time search without creating an instance
		let results = try await Fuse.search("tolkien", in: books)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.item.author, "J.R.R. Tolkien")
	}

	func testStaticStringSearch() async throws {
		let names = ["John", "Jane", "Bob"]

		// One-time search on strings
		let results = try await Fuse.search("jon", in: names)

		XCTAssertFalse(results.isEmpty)
		XCTAssertEqual(results.first?.item, "John")
	}

	// MARK: - Max Results

	func testMaxResults() async throws {
		let names = ["John Smith", "Johnny Appleseed", "John Doe", "Jonathan Swift"]

		let fuse = Fuse(data: names)
		let results = try await fuse.search("john", maxResults: 2)

		XCTAssertEqual(results.count, 2)
	}

	// MARK: - Non-blocking Init

	func testNonBlockingInit() async throws {
		// Large dataset to demonstrate non-blocking behavior
		let names = (0..<1000).map { "Name \($0)" }

		// This should return immediately
		let fuse = Fuse(data: names)

		// First search waits for index, subsequent searches are instant
		let results = try await fuse.search("Name 500")
		XCTAssertFalse(results.isEmpty)
	}

	// MARK: - Ignore Location

	func testIgnoreLocation() async throws {
		// Pattern appears at different positions in these strings
		let strings = [
			"test at start",           // "test" at position 0
			"this is a test string",   // "test" at position 10
			"end test"                 // "test" at position 4
		]

		// With ignoreLocation: false (default), location affects score
		// Default location=0 means matches near the start score better
		let fuseWithLocation = Fuse(data: strings, location: 0)
		let resultsWithLocation = try await fuseWithLocation.search("test")

		// With ignoreLocation: true, only match accuracy matters
		// All exact matches should have the same score
		let fuseIgnoreLocation = Fuse(data: strings, ignoreLocation: true)
		let resultsIgnoreLocation = try await fuseIgnoreLocation.search("test")

		// When ignoring location, all exact matches of "test" should have score 0
		for result in resultsIgnoreLocation {
			XCTAssertEqual(result.score, 0, "With ignoreLocation, exact match should have score 0")
		}

		// With location considered, scores should vary based on position
		let scoresWithLocation = resultsWithLocation.map { $0.score }
		let scoresIgnoreLocation = resultsIgnoreLocation.map { $0.score }

		print("Scores with location: \(scoresWithLocation)")
		print("Scores ignoring location: \(scoresIgnoreLocation)")

		// The scores with location should not all be equal (unless by coincidence)
		// but scores ignoring location should all be 0 for exact matches
		XCTAssertTrue(scoresIgnoreLocation.allSatisfy { $0 == 0 })
	}

	func testIgnoreLocationStatic() async throws {
		let names = ["prefix_john", "john_suffix", "mid_john_dle"]

		// Static search with ignoreLocation
		let results = try await Fuse.search("john", in: names, ignoreLocation: true)

		// All should match with score 0 (exact substring matches)
		XCTAssertEqual(results.count, 3)
		for result in results {
			XCTAssertEqual(result.score, 0)
		}
	}
}


struct Book: Fuseable {
	var author: String
	var title: String

	var fuseProperties: [String: FuseProperty] {
		return [
			"title": .init(value: title, weight: 0.3),
			"author": .init(value: author, weight: 0.7),
		]
	}
}
