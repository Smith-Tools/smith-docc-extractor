import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession-based client for accessing generic DocC JSON documentation.
/// Uses URLPatternRegistry for intelligent URL routing based on known patterns.
public class DocCJSONFetcher {

    // MARK: - Properties

    private let session: URLSession
    private let baseURL: String
    private let userAgentPool: [String]
    private let patternRegistry: URLPatternRegistry

    // MARK: - Constants

    private static let defaultUserAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    ]

    // MARK: - Errors

    public enum FetcherError: Error, LocalizedError {
        case invalidURL(String)
        case networkError(Error)
        case decodingError(Error)
        case notFound
        case invalidResponse
        case tableOfContentsPage(String) // Special case for TOC pages

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url): return "Invalid URL: \(url)"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .decodingError(let error): return "Decoding error: \(error.localizedDescription)"
            case .notFound: return "Documentation not found"
            case .invalidResponse: return "Invalid response from server"
            case .tableOfContentsPage(let message): return message
            }
        }
    }

    // MARK: - Initialization

    public init(
        baseURL: String = "https://developer.apple.com",
        patternRegistry: URLPatternRegistry = .shared
    ) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
        self.baseURL = baseURL
        self.userAgentPool = Self.defaultUserAgents
        self.patternRegistry = patternRegistry
    }

    // MARK: - Public Methods

    /// Fetch documentation using the pattern registry for URL routing
    public func fetchDocumentation(path: String) async throws -> DocCRenderNode {
        // Construct full URL for pattern matching
        let fullURLString: String
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            fullURLString = path
        } else {
            fullURLString = "\(baseURL)/\(path.hasPrefix("/") ? String(path.dropFirst()) : path)"
        }
        
        guard let url = URL(string: fullURLString) else {
            throw FetcherError.invalidURL(fullURLString)
        }
        
        // Use pattern registry for intelligent routing
        guard let (jsonPath, handler) = patternRegistry.resolveJSONPath(for: url) else {
            throw FetcherError.invalidURL("No pattern handler found for: \(fullURLString)")
        }
        
        // Check for Table of Contents pages (different schema)
        if case .tableOfContents = handler.responseType {
            throw FetcherError.tableOfContentsPage(
                "This is a Table of Contents page. Use a specific article path instead. " +
                "Example: /design/human-interface-guidelines/color"
            )
        }
        
        // Special handling for GitHub repo URLs that need resolution
        if jsonPath.hasPrefix("__github_repo__/") {
            return try await resolveGitHubRepoDocumentation(jsonPath: jsonPath)
        }
        
        // Construct final URL
        var finalPath = jsonPath
        if !finalPath.hasSuffix(".json") {
            finalPath += ".json"
        }
        
        guard let baseURLComponents = URLComponents(string: fullURLString),
              let host = baseURLComponents.host,
              let scheme = baseURLComponents.scheme else {
            throw FetcherError.invalidURL(fullURLString)
        }
        
        let finalURL = "\(scheme)://\(host)/\(finalPath)"
        
        do {
            return try await performRequest(url: finalURL)
        } catch let error as FetcherError {
            // Fallback for generic sites
            if case .notFound = error, handler.identifier == "generic.docc" {
                return try await attemptGenericFallback(originalURL: url)
            }
            throw error
        }
    }
    
    /// Resolve GitHub repo URL to actual DocC documentation
    private func resolveGitHubRepoDocumentation(jsonPath: String) async throws -> DocCRenderNode {
        // Parse __github_repo__/owner/repo
        let parts = jsonPath.replacingOccurrences(of: "__github_repo__/", with: "").split(separator: "/")
        guard parts.count >= 2 else {
            throw FetcherError.invalidURL("Invalid GitHub repo path: \(jsonPath)")
        }
        
        let owner = String(parts[0])
        let repo = String(parts[1])
        
        // Generate potential module names (Swift packages often have different module names)
        var moduleNames: [String] = []
        
        // 1. Repo name without dashes (e.g., swift-composable-architecture -> swiftcomposablearchitecture)
        moduleNames.append(repo.replacingOccurrences(of: "-", with: "").lowercased())
        
        // 2. Repo name with 'swift-' prefix stripped (common pattern)
        if repo.lowercased().hasPrefix("swift-") {
            let withoutPrefix = String(repo.dropFirst("swift-".count))
            moduleNames.append(withoutPrefix.replacingOccurrences(of: "-", with: "").lowercased())
        }
        
        // 3. Just the repo name with dashes (some use it as-is)
        moduleNames.append(repo.lowercased())
        
        let baseGHPages = "https://\(owner).github.io/\(repo)"
        
        // Build list of paths to try
        var pathsToTry: [String] = []
        
        // Unversioned paths first (most common for simple projects)
        for moduleName in moduleNames {
            pathsToTry.append("\(baseGHPages)/data/documentation/\(moduleName).json")
        }
        
        // Try recent release versions for versioned docs (like TCA)
        let recentVersions = await fetchRecentGitHubReleases(owner: owner, repo: repo)
        for version in recentVersions {
            for moduleName in moduleNames {
                pathsToTry.append("\(baseGHPages)/\(version)/data/documentation/\(moduleName).json")
            }
        }


        
        
        // Add common fallbacks (main branch and direct paths)
        for moduleName in moduleNames {
            pathsToTry.append("\(baseGHPages)/main/data/documentation/\(moduleName).json")
            pathsToTry.append("\(baseGHPages)/documentation/\(moduleName).json")
        }
        pathsToTry.append("\(baseGHPages)/main/data/documentation/\(repo).json")
        
        for urlString in pathsToTry {
            do {
                return try await performRequest(url: urlString)
            } catch {
                continue // Try next path
            }
        }
        
        // Fallback: Try to fetch .docc source markdown directly from the repo
        if let docCSource = await fetchDocCSourceFromRepo(owner: owner, repo: repo) {
            return docCSource
        }
        
        // If all paths fail, return a helpful error
        throw FetcherError.notFound
    }
    
    /// Fetch .docc source markdown directly from a GitHub repo using API tree search
    private func fetchDocCSourceFromRepo(owner: String, repo: String) async -> DocCRenderNode? {
        // Use GitHub API to find .docc directories in the repo tree
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/git/trees/main?recursive=1"
        
        guard let url = URL(string: apiURL) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgentPool.randomElement()!, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tree = json["tree"] as? [[String: Any]] else {
                return nil
            }
            
            // Find .docc directories
            var doccPaths: [String] = []
            for item in tree {
                if let path = item["path"] as? String,
                   let type = item["type"] as? String,
                   type == "tree",
                   path.hasSuffix(".docc") {
                    doccPaths.append(path)
                }
            }
            
            // Try to find main documentation markdown in each .docc directory
            for doccPath in doccPaths {
                // Look for .md files in the .docc directory
                for item in tree {
                    if let path = item["path"] as? String,
                       let type = item["type"] as? String,
                       type == "blob",
                       path.hasPrefix(doccPath + "/"),
                       path.hasSuffix(".md"),
                       !path.contains("/Guides/") { // Skip guide subdirectories first
                        
                        // Fetch the markdown content
                        let rawURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/main/\(path)"
                        if let content = try? await fetchRawContent(from: rawURL) {
                            return createRenderNodeFromMarkdown(content, owner: owner, repo: repo)
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        
        return nil
    }
    
    /// Fetch raw content from a URL
    private func fetchRawContent(from urlString: String) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(userAgentPool.randomElement()!, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return content
    }

    
    /// Convert DocC markdown to a synthetic DocCRenderNode
    private func createRenderNodeFromMarkdown(_ markdown: String, owner: String, repo: String) -> DocCRenderNode {
        // Extract title from first # heading
        let lines = markdown.components(separatedBy: "\n")
        var title = repo
        var abstract = ""
        
        for line in lines {
            if line.hasPrefix("# ") {
                // Extract title, handle ``ModuleName`` format
                title = String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "``", with: "")
                    .replacingOccurrences(of: "`", with: "")
            } else if !line.isEmpty && abstract.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("-") {
                abstract = line.trimmingCharacters(in: .whitespaces)
            }
            
            if !title.isEmpty && !abstract.isEmpty {
                break
            }
        }
        
        // Create TextFragment for abstract
        let abstractFragment = TextFragment(type: "text", text: abstract)
        
        // Create minimal DocCRenderNode with the extracted content
        return DocCRenderNode(
            metadata: DocumentationMetadata(
                role: "collection",
                roleHeading: "Package",
                title: title
            ),
            abstract: [abstractFragment],
            identifier: DocumentationIdentifier(
                url: "doc://\(owner)/\(repo)",
                interfaceLanguage: "swift"
            ),
            schemaVersion: VersionInfo(major: 0, minor: 1, patch: 0),
            kind: "article"
        )
    }


    
    /// Fetch recent release versions from GitHub API (for versioned doc fallback)
    private func fetchRecentGitHubReleases(owner: String, repo: String) async -> [String] {
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=10"
        
        guard let url = URL(string: apiURL) else { return [] }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgentPool.randomElement()!, forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }
            
            // Parse JSON to extract tag_names
            if let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var versions = Set<String>() // Use set to dedupe
                
                for release in releases {
                    guard let tagName = release["tag_name"] as? String else { continue }
                    // Remove 'v' prefix if present
                    var version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                    
                    // Normalize to major.minor.0 (many gh-pages only have major.minor versions)
                    let components = version.split(separator: ".")
                    if components.count >= 2 {
                        version = "\(components[0]).\(components[1]).0"
                    }
                    versions.insert(version)
                }
                
                // Sort versions descending (latest first)
                return versions.sorted { v1, v2 in
                    v1.compare(v2, options: .numeric) == .orderedDescending
                }
            }
        } catch {
            return []
        }
        
        return []
    }




    
    /// Get information about which handler would be used for a URL
    public func handlerInfo(for path: String) -> (identifier: String, responseType: PatternResponseType)? {
        let fullURLString = path.hasPrefix("http") ? path : "\(baseURL)/\(path)"
        guard let url = URL(string: fullURLString),
              let handler = patternRegistry.handler(for: url) else {
            return nil
        }
        return (handler.identifier, handler.responseType)
    }

    // MARK: - Private Methods
    
    private func attemptGenericFallback(originalURL: URL) async throws -> DocCRenderNode {
        // Try alternate path pattern for static DocC sites
        var path = originalURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if !path.hasPrefix("documentation/") {
            path = "documentation/\(path)"
        }
        if !path.hasSuffix(".json") {
            path += ".json"
        }
        
        guard let host = originalURL.host,
              let scheme = originalURL.scheme else {
            throw FetcherError.invalidURL(originalURL.absoluteString)
        }
        
        let url = "\(scheme)://\(host)/\(path)"
        return try await performRequest(url: url)
    }

    private func performRequest<T: Codable>(url: String, responseType: T.Type = T.self) async throws -> T {
        guard let requestURL = URL(string: url) else {
            throw FetcherError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.setValue(userAgentPool.randomElement()!, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetcherError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299: break
        case 404: throw FetcherError.notFound
        default: throw FetcherError.networkError(URLError(.badServerResponse))
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FetcherError.decodingError(error)
        }
    }
}

