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

