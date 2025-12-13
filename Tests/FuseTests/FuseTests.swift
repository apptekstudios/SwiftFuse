import XCTest
@testable import Fuse

final class FuseTests: XCTestCase {

	// MARK: - Instance-based Search (with pre-indexed data)

	func testFuseableSearch() async throws {
		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves")
		]

		// Create Fuse instance with data - index is created automatically
		let fuse = await Fuse(data: books)

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

		// Create once, search many times (fast!)
		let fuse = await Fuse(data: books)

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

		// Create Fuse instance with string data
		let fuse = await Fuse(data: names)

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

		let fuse = await Fuse(data: names)
		let results = try await fuse.search("john", maxResults: 2)

		XCTAssertEqual(results.count, 2)
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
