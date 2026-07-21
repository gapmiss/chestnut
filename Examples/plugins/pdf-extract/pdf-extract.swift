#!/usr/bin/env swift

import Foundation
import PDFKit

guard let path = ProcessInfo.processInfo.environment["CHESTNUT_FILE_PATH"],
      !path.isEmpty
else {
    fputs("No file path provided\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: path)
guard let doc = PDFDocument(url: url) else {
    fputs("Could not open PDF: \(path)\n", stderr)
    exit(1)
}

let timestamp = ProcessInfo.processInfo.environment["CHESTNUT_TIMESTAMP"]
    ?? ISO8601DateFormatter().string(from: Date())
let baseName = url.deletingPathExtension().lastPathComponent
let pageCount = doc.pageCount

let maxBytes = 800_000
var pages: [String] = []
var totalBytes = 0
var extractedPages = 0
for i in 0..<pageCount {
    if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
        let byteCount = text.utf8.count
        if totalBytes + byteCount > maxBytes { break }
        pages.append(text)
        totalBytes += byteCount + 7 // separator overhead
    }
    extractedPages = i + 1
}

let truncated = extractedPages < pageCount
let text = pages.joined(separator: "\n\n---\n\n")
let wordCount = text.split(separator: " ").count

var parts: [String] = []
parts.append("---")
parts.append("title: \"\(yamlEscape(baseName))\"")
parts.append("source: pdf")
parts.append("pages: \(pageCount)")
parts.append("date: \(timestamp)")
parts.append("tags: [pdf, extract]")
parts.append("---")
parts.append("")
parts.append("# \(baseName)")
parts.append("")
parts.append("**\(pageCount) pages** · \(wordCount) words")
parts.append("")

if pages.isEmpty {
    parts.append("> *No extractable text found in this PDF.*")
} else {
    if truncated {
        parts.append("> *Extracted \(extractedPages) of \(pageCount) pages (size limit).*")
        parts.append("")
    }
    parts.append(text)
}
parts.append("")

let content = parts.joined(separator: "\n")
let safeBase = baseName
    .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "", options: .regularExpression)
    .prefix(80)
let filename = "\(safeBase).md"

let notify = pages.isEmpty
    ? "No text found"
    : "\(wordCount) words from \(pageCount) pages"

let envelope: [String: Any] = [
    "action": "save",
    "content": content,
    "filename": filename,
    "vault": "ask",
    "notify": notify,
]

guard let json = try? JSONSerialization.data(
    withJSONObject: envelope, options: []
) else {
    fputs("Failed to encode JSON output\n", stderr)
    exit(1)
}

FileHandle.standardOutput.write(json)

func yamlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}
