import XCTest
@testable import FuseForkSwift

final class FuseForkSwiftTests: XCTestCase {

	func testExample() throws {
		

		let books: [Book] = [
			Book(author: "John X", title: "Old Man's War fiction"),
			Book(author: "P.D. Mans", title: "Right Ho Jeeves")
		]
		
		let fuse = Fuse()
		var results: [Fuse.FusableSearchResult<Book>] = []
		let time = ContinuousClock().measure {
			results = fuse.search("odmanfict", in: books)
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
