import ArgumentParser
import Foundation
import Logging
import SmithDoccExtractor

// MARK: - Main CLI

@main
struct SmithDoccExtractorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smith-doc-inspector",
        abstract: "Inspect DocC documentation and repo examples from URLs, GitHub repos, and local projects",
        discussion: """
        Smith Docc Extractor fetches and extracts documentation from various sources:
        
        Examples:
          smith-doc-inspector docs https://developer.apple.com/documentation/swiftui
          smith-doc-inspector docs https://github.com/apple/swift-nio
          smith-doc-inspector docs /path/to/local/project
          smith-doc-inspector list                    # List project dependencies with doc status
          smith-doc-inspector examples swift-nio      # Find code examples
        """,
        version: "2.0.0",
        subcommands: [Docs.self, List.self, Examples.self],
        defaultSubcommand: Docs.self
    )
}

// MARK: - Output Format

enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json
    case text
}

// MARK: - Docs Command (previously Extract)

struct Docs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract documentation from a URL or local path",
        aliases: ["extract"]
    )

    @Argument(help: "URL or local path to extract documentation from")
    var source: String

    @Option(help: "Output format (json, text)")
    var format: OutputFormat = .text
    
    @Option(help: "Truncate output to N characters (0 for unlimited)")
    var limit: Int = 0
    
    @Flag(help: "Enable verbose logging")
    var verbose = false

    mutating func run() async throws {
        // Check if input is a local path
        if isLocalPath(source) {
            try await extractFromLocalPath(source)
            return
        }
        
        // URL-based extraction
        let targetURL = normalizeURL(source)
        
        guard let urlComponents = URLComponents(string: targetURL),
              let host = urlComponents.host,
              let scheme = urlComponents.scheme else {
            print("Error: Invalid URL")
            throw ExitCode.validationFailure
        }
        
        let baseURL = "\(scheme)://\(host)"
        let path = urlComponents.path 
        
        let fetcher = DocCJSONFetcher(baseURL: baseURL)
        
        do {
            let doc = try await fetcher.fetchDocumentation(path: path)
            outputResult(doc)
        } catch {
            print("Error extracting documentation: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
    
    private func isLocalPath(_ input: String) -> Bool {
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
        
        // Search in SPM checkouts
        for checkoutPath in [".build/checkouts", "swiftpm-temp/checkouts"] {
            let checkoutsURL = projectURL.appendingPathComponent(checkoutPath)
            if fileManager.fileExists(atPath: checkoutsURL.path) {
                doccDirs.append(contentsOf: try findDoccDirectories(in: checkoutsURL))
            }
        }
        
        if doccDirs.isEmpty {
            print("No .docc documentation found in \(path)")
            throw ExitCode.failure
        }
        
        // Extract from first (or prioritized) .docc
        for doccDir in doccDirs {
            if let markdown = try extractFromDoccDirectory(doccDir) {
                let title = doccDir.deletingPathExtension().lastPathComponent
                var output = "# \(title)\n\(markdown)"
                
                if limit > 0 && output.count > limit {
                    output = String(output.prefix(limit)) + "\n... (truncated)"
                }
                print(output)
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
        
        let doccName = doccURL.deletingPathExtension().lastPathComponent.lowercased()
        
        let mdFiles = contents.filter { $0.pathExtension == "md" }
            .sorted { url1, url2 in
                let name1 = url1.deletingPathExtension().lastPathComponent.lowercased()
                let name2 = url2.deletingPathExtension().lastPathComponent.lowercased()
                
                if name1.hasPrefix(doccName) != name2.hasPrefix(doccName) {
                    return name1.hasPrefix(doccName)
                }
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
                var output = String(data: data, encoding: .utf8) ?? ""
                if limit > 0 && output.count > limit {
                    output = String(output.prefix(limit)) + "\n... (truncated)"
                }
                print(output)
            }
            
        case .text:
            let title = doc.metadata?.title ?? "Untitled"
            var output = "# \(title)\n"
            if let abstract = doc.abstract {
                output += abstract.compactMap { $0.text }.joined(separator: "")
            }
            if limit > 0 && output.count > limit {
                output = String(output.prefix(limit)) + "\n... (truncated)"
            }
            print(output)
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

// MARK: - List Command

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List project dependencies and their documentation status"
    )

    @Option(help: "Path to the project directory")
    var path: String = "."
    
    @Flag(help: "Fetch documentation for all dependencies")
    var fetchDocs = false

    @Option(help: "Output format (json, text)")
    var format: OutputFormat = .text

    mutating func run() async throws {
        let projectPath = NSString(string: path).expandingTildeInPath
        let projectURL = URL(fileURLWithPath: projectPath)
        
        // Look for Package.resolved
        let resolvedPath = projectURL.appendingPathComponent("Package.resolved")
        
        guard FileManager.default.fileExists(atPath: resolvedPath.path) else {
            print("Error: Package.resolved not found in \(path)")
            print("Run 'swift package resolve' first")
            throw ExitCode.failure
        }
        
        // Parse Package.resolved
        guard let data = FileManager.default.contents(atPath: resolvedPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Error: Failed to parse Package.resolved")
            throw ExitCode.failure
        }
        
        // Extract packages (both v1 and v2 formats)
        var packages: [(name: String, url: String?)] = []
        
        if let pins = json["pins"] as? [[String: Any]] {
            // v2 format
            for pin in pins {
                let identity = pin["identity"] as? String ?? "unknown"
                let location = pin["location"] as? String
                packages.append((identity, location))
            }
        } else if let object = json["object"] as? [String: Any],
                  let pins = object["pins"] as? [[String: Any]] {
            // v1 format
            for pin in pins {
                let name = pin["package"] as? String ?? "unknown"
                let repo = pin["repositoryURL"] as? String
                packages.append((name, repo))
            }
        }
        
        if packages.isEmpty {
            print("No dependencies found")
            return
        }
        
        switch format {
        case .json:
            let jsonOutput = packages.map { ["name": $0.name, "url": $0.url ?? ""] }
            if let data = try? JSONSerialization.data(withJSONObject: jsonOutput, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            
        case .text:
            print("\n📦 Dependencies (\(packages.count) packages)")
            print(String(repeating: "─", count: 50))
            
            for pkg in packages {
                var line = "• \(pkg.name)"
                if let url = pkg.url {
                    // Extract owner/repo from GitHub URL
                    if url.contains("github.com") {
                        let parts = url.replacingOccurrences(of: ".git", with: "")
                            .split(separator: "/")
                        if parts.count >= 2 {
                            let repo = parts.suffix(2).joined(separator: "/")
                            line += " (\(repo))"
                        }
                    }
                }
                print(line)
            }
            
            if fetchDocs {
                print("\n📚 Fetching documentation...")
                for pkg in packages {
                    if let url = pkg.url {
                        do {
                            let fetcher = DocCJSONFetcher(baseURL: "https://github.com")
                            let doc = try await fetcher.fetchDocumentation(path: url)
                            print("✅ \(pkg.name): \(doc.metadata?.title ?? "Found")")
                        } catch {
                            print("⚠️  \(pkg.name): No DocC found")
                        }
                    }
                }
            } else {
                print("\nUse --fetch-docs to fetch documentation for all packages")
            }
        }
    }
}

// MARK: - Examples Command

struct Examples: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find code examples in a GitHub repository"
    )

    @Argument(help: "Package name or GitHub URL")
    var package: String
    
    @Option(help: "Filter examples by keyword")
    var filter: String?
    
    @Option(help: "Maximum number of examples")
    var limit: Int = 10

    mutating func run() async throws {
        // Construct GitHub URL if just a package name
        var repoURL = package
        if !package.contains("github.com") {
            // Try common patterns
            repoURL = "https://github.com/apple/\(package)"
        }
        
        guard let url = URL(string: repoURL),
              let host = url.host,
              host.contains("github.com") else {
            print("Error: Invalid GitHub URL")
            throw ExitCode.failure
        }
        
        // Extract owner/repo
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
        let components = path.split(separator: "/")
        
        guard components.count >= 2 else {
            print("Error: Could not parse owner/repo from URL")
            throw ExitCode.failure
        }
        
        let owner = String(components[0])
        let repo = String(components[1])
        
        print("🔍 Searching for examples in \(owner)/\(repo)...")
        
        // Use GitHub API to find example files
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/git/trees/main?recursive=1"
        
        guard let requestURL = URL(string: apiURL) else {
            throw ExitCode.failure
        }
        
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = json["tree"] as? [[String: Any]] else {
            print("Error: Could not fetch repository structure")
            throw ExitCode.failure
        }
        
        // Find example files
        let examplePatterns = ["Example", "Demo", "Sample", "Playground", "Tests"]
        var exampleFiles: [String] = []
        
        for item in tree {
            guard let path = item["path"] as? String,
                  let type = item["type"] as? String,
                  type == "blob",
                  path.hasSuffix(".swift") else { continue }
            
            let matches = examplePatterns.contains { path.contains($0) }
            let filterMatch = filter == nil || path.lowercased().contains(filter!.lowercased())
            
            if matches && filterMatch {
                exampleFiles.append(path)
            }
        }
        
        if exampleFiles.isEmpty {
            print("No example files found")
            return
        }
        
        print("\n💡 Found \(exampleFiles.count) example files:")
        print(String(repeating: "─", count: 50))
        
        for (index, file) in exampleFiles.prefix(limit).enumerated() {
            print("\(index + 1). \(file)")
        }
        
        if exampleFiles.count > limit {
            print("\n... and \(exampleFiles.count - limit) more. Use --limit to see more.")
        }
    }
}
