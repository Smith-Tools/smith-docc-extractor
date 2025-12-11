import Foundation

/// Documentation content from a package
public struct PackageDocumentation: Codable, Sendable {
    public let packageName: String
    public let version: String?
    public let content: String
    public let type: DocumentationType
    public let url: String?
    public let extractedAt: Date

    public enum DocumentationType: String, Codable, Sendable {
        case readme
        case docc
        case guide
        case tutorial
        case apiReference
    }

    public init(packageName: String, version: String? = nil, content: String, type: DocumentationType, url: String? = nil) {
        self.packageName = packageName
        self.version = version
        self.content = content
        self.type = type
        self.url = url
        self.extractedAt = Date()
    }
}
