
import Foundation

public protocol Fuseable: Sendable {
	var fuseProperties: [String: FuseProperty] { get }
}

public struct FuseProperty: Sendable {
	public let value: String
	public let weight: Double

	public init(value: String, weight: Double = 1) {
		self.value = value
		self.weight = weight
	}
}
