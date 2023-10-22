
import Foundation

public protocol Fuseable {
	var fuseProperties: [String: FuseProperty] { get }
}

public struct FuseProperty {
	let value: String
	let weight: Double
	
	public init (value: String, weight: Double = 1) {
		self.value = value
		self.weight = weight
	}
}
