import ArgumentParser
import Foundation
import Logging
import SmithDocExtractor

// Define standard logging bootstrap since this is a CLI
private func bootstrapLogging() {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = .info
        return handler
    }
}

@main
struct SmithDocExtractorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smith-doc-extractor",
        abstract: "Extract DocC documentation from public JSON endpoints",
        version: "1.0.0",
        subcommands: [Extract.self],
        defaultSubcommand: Extract.self
    )
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract documentation from a specific URL"
    )

    @Argument(help: "The URL to extracted documentation from (e.g., https://developer.apple.com/documentation/swiftui)")
    var url: String

    @Option(help: "Output format (json, text)")
    var format: OutputFormat = .json
    
    @Flag(help: "Enable verbose logging")
    var verbose = false

    enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case text
    }

    mutating func run() async throws {
        if verbose {
            var logger = Logger(label: "smith-doc-extractor")
            logger.logLevel = .debug
        }
        
        // bootstrap logging if needed, or rely on print for simple CLI output
        
        // Simple heuristic: if it looks like a full URL, use it directly or parse it.
        // The fetcher needs to be smart enough or we handle it here.
        // DocCJSONFetcher logic assumes a baseURL is set.
        // Let's adapt:
        
        let targetURL = normalizeURL(url)
        
        // We'll reconstruct a fetcher for the specific host of the target URL to reuse existing logic
        guard let urlComponents = URLComponents(string: targetURL),
              let host = urlComponents.host,
              let scheme = urlComponents.scheme else {
            print("Error: Invalid URL")
            throw ExitCode.validationFailure
        }
        
        let baseURL = "\(scheme)://\(host)"
        let path = urlComponents.path 
        
        let specificFetcher = DocCJSONFetcher(baseURL: baseURL)
        
        do {
            let doc = try await specificFetcher.fetchDocumentation(path: path)
            
            switch format {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(doc)
                print(String(data: data, encoding: .utf8) ?? "")
                
            case .text:
                // Simple text extraction for now
                let title = doc.metadata?.title ?? "Untitled"
                print("# \(title)")
                if let abstract = doc.abstract {
                    print(abstract.compactMap { $0.text }.joined(separator: ""))
                }
                // We could expand this to render full markdown if we move Renderer to common
                // For now, just basic dump
            }
            
        } catch {
            print("Error extracting documentation: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
    
    private func normalizeURL(_ input: String) -> String {
        var url = input
        if !url.lowercased().hasPrefix("http") {
            url = "https://" + url
        }
        return url
    }
}
