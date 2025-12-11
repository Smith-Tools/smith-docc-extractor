import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession-based client for accessing generic DocC JSON documentation.
/// Based on sosumi.ai implementation for accessing undocumented Apple endpoints.
/// Generalized to support any DocC host.
public class DocCJSONFetcher {

    // MARK: - Properties

    private let session: URLSession
    private let baseURL: String
    private let userAgentPool: [String]

    // MARK: - Constants

    /// List of Safari user agents for rotation (for hosts that care)
    private static let defaultUserAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    ]

    // MARK: - Errors

    public enum FetcherError: Error, LocalizedError {
        case invalidURL(String)
        case networkError(Error)
        case decodingError(Error)
        case notFound
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid URL: \(url)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .decodingError(let error):
                return "Decoding error (DocC schema mismatch): \(error.localizedDescription)"
            case .notFound:
                return "Documentation not found"
            case .invalidResponse:
                return "Invalid response from server"
            }
        }
    }

    // MARK: - Initialization

    /// Initializes the fetcher with a base URL (e.g., "https://developer.apple.com")
    public init(baseURL: String = "https://developer.apple.com") {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
        self.baseURL = baseURL
        self.userAgentPool = Self.defaultUserAgents
    }

    // MARK: - Public Methods

    /// Fetches documentation for a specific path relative to the base URL
    public func fetchDocumentation(path: String) async throws -> DocCRenderNode {
        let normalizedPath = normalizeDocumentationPath(path)
        // Assume standard DocC routing: .json is appended to the path
        let url = "\(baseURL)/\(normalizedPath).json"
        return try await performRequest(url: url)
    }

    // MARK: - Private Methods

    /// Performs a network request and decodes the response
    private func performRequest<T: Codable>(url: String, responseType: T.Type = T.self) async throws -> T {
        guard let requestURL = URL(string: url) else {
            throw FetcherError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.setValue(selectRandomUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw FetcherError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...299:
                break
            case 404:
                throw FetcherError.notFound
            default:
                throw FetcherError.networkError(URLError(.badServerResponse))
            }

            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch {
                throw FetcherError.decodingError(error)
            }

        } catch {
            if let clientError = error as? FetcherError {
                throw clientError
            } else {
                throw FetcherError.networkError(error)
            }
        }
    }

    /// Selects a random User Agent from the pool
    private func selectRandomUserAgent() -> String {
        return userAgentPool.randomElement() ?? Self.defaultUserAgents[0]
    }

    /// Normalizes a documentation path (removes .json, ensures proper format)
    /// This logic is generalized but heavily influenced by Apple's routing
    private func normalizeDocumentationPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "documentation"
        }

        // Clean up common prefixes
        if normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        // Remove .json suffix if present
        if normalized.hasSuffix(".json") {
            normalized = normalized.replacingOccurrences(of: ".json", with: "")
        }

        // Ensure documentation/ prefix for standard DocC sites
        // Note: Some static sites might not use "documentation/", but it's the standard default
        // Detect Apple Developer domains for special routing
        if baseURL.contains("developer.apple.com") {
             if !normalized.contains("tutorials/data/documentation") {
                 // Convert standard "documentation/foo" -> "tutorials/data/documentation/foo"
                 if normalized.hasPrefix("documentation/") {
                     normalized = "tutorials/data/" + normalized
                 } else {
                     normalized = "tutorials/data/documentation/" + normalized
                 }
             }
        } else {
            // Standard DocC (SwiftPackageIndex, static hosting, etc) usually uses data/documentation
            // or just documentation/..json depending on hosting. 
            // Most modern dynamic DocC uses /data/documentation/
            
            // If the path was passed as "documentation/foo", try to convert to data/documentation/foo 
            // IF we suspect it's a dynamic host. But let's be conservative:
            // If it doesn't have "data/" or "documentation/", add "documentation/"
            
            if !normalized.contains("/documentation/") && 
               !normalized.contains("/tutorials/") && 
               !normalized.hasPrefix("documentation/") && 
               !normalized.hasPrefix("tutorials/") {
                normalized = "documentation/\(normalized)"
            }
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
