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
        
        // Check if input is a local path
        if isLocalPath(url) {
            try await extractFromLocalPath(url)
            return
        }
        
        // URL-based extraction
        let targetURL = normalizeURL(url)
        
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
            outputResult(doc)
        } catch {
            print("Error extracting documentation: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
    
    private func isLocalPath(_ input: String) -> Bool {
        // Detect local paths (start with / or ~, or exist as directory)
        return input.hasPrefix("/") || 
               input.hasPrefix("~") || 
               input.hasPrefix("./") ||
               FileManager.default.fileExists(atPath: input)
    }
    
    private func extractFromLocalPath(_ path: String) async throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let projectURL = URL(fileURLWithPath: expandedPath)
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("Error: Path does not exist: \(expandedPath)")
            throw ExitCode.failure
        }
        
        // Search for .docc directories
        var doccDirs: [URL] = []
        let fileManager = FileManager.default
        
        // Search in Sources/ first (main project docs)
        let sourcesURL = projectURL.appendingPathComponent("Sources")
        if fileManager.fileExists(atPath: sourcesURL.path) {
            doccDirs.append(contentsOf: try findDoccDirectories(in: sourcesURL))
        }
        
        // Search in SPM checkouts (.build/checkouts/)
        let checkoutsURL = projectURL.appendingPathComponent(".build/checkouts")
        if fileManager.fileExists(atPath: checkoutsURL.path) {
            doccDirs.append(contentsOf: try findDoccDirectories(in: checkoutsURL))
        }
        
        // Alternative checkout location (swiftpm-temp/checkouts/)
        let swiftpmCheckoutsURL = projectURL.appendingPathComponent("swiftpm-temp/checkouts")
        if fileManager.fileExists(atPath: swiftpmCheckoutsURL.path) {
            doccDirs.append(contentsOf: try findDoccDirectories(in: swiftpmCheckoutsURL))
        }
        
        if doccDirs.isEmpty {
            print("No .docc documentation found in \(path)")
            throw ExitCode.failure
        }
        
        // Extract from first (or prioritized) .docc
        for doccDir in doccDirs {
            if let markdown = try extractFromDoccDirectory(doccDir) {
                let title = doccDir.deletingPathExtension().lastPathComponent
                print("# \(title)")
                print(markdown)
                return
            }
        }
        
        print("Could not extract content from any .docc directory")
        throw ExitCode.failure
    }
    
    private func findDoccDirectories(in directory: URL) throws -> [URL] {
        var results: [URL] = []
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }
        
        for case let url as URL in enumerator {
            if url.pathExtension == "docc" {
                results.append(url)
            }
        }
        
        return results
    }
    
    private func extractFromDoccDirectory(_ doccURL: URL) throws -> String? {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: doccURL, includingPropertiesForKeys: nil)
        
        // Find main markdown file (matching directory name or Overview)
        let doccName = doccURL.deletingPathExtension().lastPathComponent.lowercased()
        
        let mdFiles = contents.filter { $0.pathExtension == "md" }
            .sorted { url1, url2 in
                let name1 = url1.deletingPathExtension().lastPathComponent.lowercased()
                let name2 = url2.deletingPathExtension().lastPathComponent.lowercased()
                
                // Prioritize module-named files
                if name1.hasPrefix(doccName) != name2.hasPrefix(doccName) {
                    return name1.hasPrefix(doccName)
                }
                
                // Then overview
                if name1.contains("overview") != name2.contains("overview") {
                    return name1.contains("overview")
                }
                
                return name1 < name2
            }
        
        if let firstMD = mdFiles.first {
            return try String(contentsOf: firstMD, encoding: .utf8)
        }
        
        return nil
    }
    
    private func outputResult(_ doc: DocCRenderNode) {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(doc) {
                print(String(data: data, encoding: .utf8) ?? "")
            }
            
        case .text:
            let title = doc.metadata?.title ?? "Untitled"
            print("# \(title)")
            if let abstract = doc.abstract {
                print(abstract.compactMap { $0.text }.joined(separator: ""))
            }
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
