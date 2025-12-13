import XCTest
@testable import Fuse

final class FuseForkSwiftTests: XCTestCase {

	func testExample() async throws {

		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves")
		]

		let fuse = await Fuse()
		var results: [Fuse.FusableSearchResult<Book>] = []
		let time = await ContinuousClock().measure {
			results = try! await fuse.search("odmanfict", in: books)
		}
		print(time.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 0, fractionalSecondsLength: 5, roundFractionalSeconds: .up))))

		for result in results {
			for (key, match) in result.resultsByKey {
				switch key {
				case "author":
					print("MATCHED AUTHOR: \(result.item.author)")
					for range in match.ranges {
						print("RANGE: \(result.item.author[range])")
					}
				case "title":
					print("MATCHED TITLE: \(result.item.title)")
					for range in match.ranges {
						print("RANGE: \(result.item.title[range])")
					}
				default:
					break
				}
			}
		}
	}

	func testIndexedSearch() async throws {
		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves"),
			Book(author: "J.R.R. Tolkien", title: "The Lord of the Rings"),
			Book(author: "George Orwell", title: "1984")
		]

		let fuse = await Fuse()

		// Create an index once for the dataset
		let index = await fuse.createIndex(from: books)

		// Perform multiple searches using the index (faster for repeated searches)
		let queries = ["tolkien", "man", "orwell", "rings"]
		for query in queries {
			let results = try await fuse.search(query, in: index)
			print("Query '\(query)': found \(results.count) results")
			for result in results {
				print("  - \(result.item.title) by \(result.item.author) (score: \(result.score))")
			}
		}
	}

	func testIndexedStringSearch() async throws {
		let names = ["John Smith", "Jane Doe", "Bob Wilson", "Alice Johnson"]

		let fuse = await Fuse()

		// Create an index for string array
		let index = await fuse.createIndex(from: names)

		// Search using the index
		let results = try await fuse.search("john", in: index)
		XCTAssertEqual(results.count, 2) // "John Smith" and "Alice Johnson"
		print("Found \(results.count) matches for 'john'")
		for result in results {
			print("  - \(result.string) (score: \(result.result.score))")
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
