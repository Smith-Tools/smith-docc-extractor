import Foundation

// MARK: - URL Pattern Handler Protocol

/// Protocol for handling special URL patterns.
/// Each handler knows how to route specific URL patterns to their correct JSON endpoints.
public protocol URLPatternHandler {
    /// Unique identifier for this handler
    var identifier: String { get }
    
    /// Priority (higher = checked first). Use 100 for specific patterns, 0 for generic fallback.
    var priority: Int { get }
    
    /// Check if this handler can process the given URL
    func canHandle(url: URL) -> Bool
    
    /// Transform the URL path to the correct JSON endpoint path
    func resolveJSONPath(for url: URL) -> String
    
    /// The response type this pattern returns (for schema validation)
    var responseType: PatternResponseType { get }
}

/// Types of responses that patterns can return
public enum PatternResponseType {
    case renderNode       // Standard DocCRenderNode
    case tableOfContents  // TOC/Index page (different schema)
    case searchIndex      // Search index data
    case custom(String)   // Custom type identifier
}

// MARK: - Built-in Pattern Handlers

/// Apple Developer Documentation (frameworks, symbols)
/// Matches: developer.apple.com/documentation/*
public struct AppleDocumentationHandler: URLPatternHandler {
    public let identifier = "apple.documentation"
    public let priority = 100
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        guard url.host?.contains("developer.apple.com") == true else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/documentation/") || 
               (!path.contains("human-interface-guidelines") && 
                !path.hasPrefix("/tutorials/") &&
                !path.hasPrefix("/design/"))
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Normalize path
        if !path.hasPrefix("documentation/") {
            path = "documentation/\(path)"
        }
        
        // Apple uses /tutorials/data/documentation/ for framework docs
        return "tutorials/data/\(path)"
    }
}

/// Apple Human Interface Guidelines (leaf pages)
/// Matches: developer.apple.com/design/human-interface-guidelines/*
public struct AppleHIGHandler: URLPatternHandler {
    public let identifier = "apple.hig"
    public let priority = 110 // Higher than general docs
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        guard url.host?.contains("developer.apple.com") == true else { return false }
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // HIG leaf pages: design/human-interface-guidelines/search-fields (has content after base)
        // Must contain HIG and have at least 3 segments: design / human-interface-guidelines / <topic>
        let segments = path.split(separator: "/")
        return path.contains("human-interface-guidelines") && segments.count >= 3
    }

    
    public func resolveJSONPath(for url: URL) -> String {
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Remove /design/ prefix if present
        if path.hasPrefix("design/") {
            path = String(path.dropFirst("design/".count))
        }
        
        return "tutorials/data/design/\(path)"
    }
}

/// Apple HIG Table of Contents (root page)
/// Matches: developer.apple.com/design/human-interface-guidelines (exactly)
public struct AppleHIGTableOfContentsHandler: URLPatternHandler {
    public let identifier = "apple.hig.toc"
    public let priority = 120 // Highest for HIG
    public let responseType = PatternResponseType.tableOfContents
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        guard url.host?.contains("developer.apple.com") == true else { return false }
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Exact match for HIG root
        return path == "design/human-interface-guidelines" ||
               path == "design/human-interface-guidelines/"
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        return "tutorials/data/design/human-interface-guidelines"
    }
}

/// Apple Tutorials
/// Matches: developer.apple.com/tutorials/*
public struct AppleTutorialsHandler: URLPatternHandler {
    public let identifier = "apple.tutorials"
    public let priority = 100
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        guard url.host?.contains("developer.apple.com") == true else { return false }
        return url.path.lowercased().hasPrefix("/tutorials/")
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if !path.hasPrefix("tutorials/data/") {
            // tutorials/swiftui -> tutorials/data/tutorials/swiftui
            return "tutorials/data/\(path)"
        }
        return path
    }
}

/// Swift Package Index (swiftpackageindex.com)
/// Matches: swiftpackageindex.com/*/documentation/*
public struct SwiftPackageIndexHandler: URLPatternHandler {
    public let identifier = "swiftpackageindex"
    public let priority = 100
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        return url.host?.contains("swiftpackageindex.com") == true
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // SPI uses /data/documentation/
        if path.hasPrefix("data/") {
            return path
        }
        
        if path.hasPrefix("documentation/") {
            return "data/\(path)"
        }
        
        return "data/documentation/\(path)"
    }
}

/// GitHub Repository URLs (github.com/owner/repo)
/// Matches: github.com/owner/repo or github.com/owner/repo.git
/// Redirects to: owner.github.io/repo/data/documentation/repo.json
public struct GitHubRepoHandler: URLPatternHandler {
    public let identifier = "github.repo"
    public let priority = 80 // Above generic, below specific doc handlers
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        guard url.host == "github.com" || url.host == "www.github.com" else { return false }
        // Must have at least /owner/repo in path
        let components = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
            .split(separator: "/")
        return components.count >= 2
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        // Extract owner and repo from github.com/owner/repo
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
        let components = path.split(separator: "/")
        
        guard components.count >= 2 else {
            return "data/documentation/\(path)"
        }
        
        let owner = String(components[0]).lowercased()
        let repo = String(components[1]).lowercased()
        
        // The actual fetch will need to redirect to owner.github.io/repo/...
        // For now, construct the expected GitHub Pages path
        // The DocCJSONFetcher will need to handle this specially
        return "__github_repo__/\(owner)/\(repo)"
    }
}


/// GitHub Pages hosted DocC (*.github.io sites with versioned or unversioned docs)
/// Matches: *.github.io/*/documentation/* or *.github.io/*/version/documentation/*
/// Pattern: preserves prefix path (repo name, version) and adds /data/ before /documentation/
public struct GitHubPagesDocCHandler: URLPatternHandler {
    public let identifier = "github.pages.docc"
    public let priority = 50 // Above generic but below specific handlers
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        return url.host?.hasSuffix(".github.io") == true
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // GitHub Pages DocC uses /data/documentation/ pattern
        // Input: pointfreeco.github.io/swift-composable-architecture/1.22.0/documentation/composablearchitecture
        // Output: swift-composable-architecture/1.22.0/data/documentation/composablearchitecture
        
        // Find where /documentation/ starts
        if let docRange = path.range(of: "documentation/") {
            // Insert /data/ before /documentation/
            let prefix = path[..<docRange.lowerBound]
            let suffix = path[docRange.lowerBound...]
            return "\(prefix)data/\(suffix)"
        }
        
        // If path ends with documentation (no trailing slash or content)
        if path.hasSuffix("/documentation") || path == "documentation" {
            if let docRange = path.range(of: "documentation") {
                let prefix = path[..<docRange.lowerBound]
                let suffix = path[docRange.lowerBound...]
                return "\(prefix)data/\(suffix)"
            }
        }
        
        // Fallback: wrap with data/documentation if not present
        if path.contains("/data/") {
            return path
        }
        return "data/documentation/\(path)"
    }
}

/// Generic DocC fallback (any other DocC-hosted site)
/// Matches: Any URL not handled by specific handlers
public struct GenericDocCHandler: URLPatternHandler {
    public let identifier = "generic.docc"
    public let priority = 0 // Lowest priority - fallback
    public let responseType = PatternResponseType.renderNode
    
    public init() {}
    
    public func canHandle(url: URL) -> Bool {
        return true // Always matches as fallback
    }
    
    public func resolveJSONPath(for url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // Try /data/documentation/ pattern first (common for dynamic DocC hosting)
        if path.hasPrefix("data/") {
            return path
        }
        
        if path.hasPrefix("documentation/") {
            return "data/\(path)"
        }
        
        return "data/documentation/\(path)"
    }

}

// MARK: - URL Pattern Registry

/// Registry for managing URL pattern handlers.
/// Patterns are checked in priority order (highest first).
public final class URLPatternRegistry: @unchecked Sendable {
    
    /// Shared default registry with built-in handlers
    public static let shared: URLPatternRegistry = {
        let registry = URLPatternRegistry()
        registry.registerInternal(AppleHIGTableOfContentsHandler())
        registry.registerInternal(AppleHIGHandler())
        registry.registerInternal(AppleTutorialsHandler())
        registry.registerInternal(AppleDocumentationHandler())
        registry.registerInternal(SwiftPackageIndexHandler())
        registry.registerInternal(GitHubRepoHandler())
        registry.registerInternal(GitHubPagesDocCHandler())
        registry.registerInternal(GenericDocCHandler())
        return registry
    }()
    
    private var handlers: [any URLPatternHandler] = []
    private let lock = NSLock()
    
    public init() {}
    
    /// Internal registration (used during initialization, no locking needed)
    private func registerInternal(_ handler: any URLPatternHandler) {
        handlers.append(handler)
        handlers.sort { $0.priority > $1.priority }
    }
    
    /// Register a new pattern handler (thread-safe)
    public func register(_ handler: any URLPatternHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append(handler)
        // Sort by priority (descending)
        handlers.sort { $0.priority > $1.priority }
    }

    
    /// Find the handler for a given URL
    public func handler(for url: URL) -> URLPatternHandler? {
        return handlers.first { $0.canHandle(url: url) }
    }
    
    /// Resolve the JSON path for a URL
    public func resolveJSONPath(for url: URL) -> (path: String, handler: URLPatternHandler)? {
        guard let handler = handler(for: url) else { return nil }
        return (handler.resolveJSONPath(for: url), handler)
    }
    
    /// List all registered handlers (for debugging)
    public var registeredHandlers: [String] {
        return handlers.map { "\($0.identifier) (priority: \($0.priority))" }
    }
}
