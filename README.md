# Smith DocC Extractor

A generic Swift library and CLI for extracting content from DocC-generated JSON documentation sites.

## Overview

`smith-docc-extractor` provides tools to fetch, parse, and extract structured data from any website hosted using Apple's DocC (Documentation Compiler). It generalizes the logic previously locked inside specialized tools, making it available for any Swift tooling needs.

## Features

- **Generic JSON Fetcher**: Works with any DocC-hosted site (e.g., Apple Developer, Swift Package Index, GitHub Pages).
- **Strongly Typed Models**: Complete Swift codable structs for the DocC RenderNode JSON schema (`DocCRenderNode`).
- **Standalone CLI**: `smith-doc-extractor` command line tool for quick extraction.
- **Library Integration**: well-factored Swift Package for use in other tools (like `scully` and `sosumi`).

## Installation

### As a Library

Add detailed dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/smith-tools/smith-doc-extractor", from: "1.0.0")
```

### CLI Usage

Build and run:

```bash
swift build -c release
.build/release/smith-doc-extractor extract https://developer.apple.com/documentation/swiftui
```

## Usage

### CLI

```bash
# Extract to JSON (default)
smith-doc-extractor extract https://developer.apple.com/documentation/swiftui

# Extract to plain text summary
smith-doc-extractor extract https://developer.apple.com/documentation/swiftui --format text
```

### Library

```swift
import SmithDocExtractor

let fetcher = DocCJSONFetcher(baseURL: "https://developer.apple.com")
let doc = try await fetcher.fetchDocumentation(path: "/documentation/swiftui")

print(doc.metadata.title)
```

## Architecture

- **DocCRenderNode**: The core data model reflecting the JSON schema.
- **DocCJSONFetcher**: A URLSession-based client handling DocC routing and normalization.
- **URLPatternRegistry**: Extensible pattern-matching system for URL routing.

## URL Pattern Handlers

The library uses a priority-based pattern registry to route URLs to their correct JSON endpoints. Built-in handlers:

| Handler | Priority | Description |
|---------|----------|-------------|
| `apple.hig.toc` | 120 | HIG root page (returns TOC error with guidance) |
| `apple.hig` | 110 | HIG leaf pages (e.g., `/design/human-interface-guidelines/color`) |
| `apple.documentation` | 100 | Apple framework docs (e.g., `/documentation/swiftui`) |
| `apple.tutorials` | 100 | Apple tutorials |
| `swiftpackageindex` | 100 | Swift Package Index DocC sites |
| `generic.docc` | 0 | Fallback for any other DocC site |

### Adding Custom Handlers

```swift
struct MyCustomHandler: URLPatternHandler {
    let identifier = "my.custom"
    let priority = 150 // Higher = checked first
    let responseType = PatternResponseType.renderNode
    
    func canHandle(url: URL) -> Bool {
        return url.host?.contains("mydocs.example.com") == true
    }
    
    func resolveJSONPath(for url: URL) -> String {
        return "api/docs/\(url.path)"
    }
}

// Register at runtime
URLPatternRegistry.shared.register(MyCustomHandler())
```
