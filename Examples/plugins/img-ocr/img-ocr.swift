#!/usr/bin/env swift

import Foundation
import Vision

guard let imagePath = ProcessInfo.processInfo.environment["CHESTNUT_FILE_PATH"],
      !imagePath.isEmpty
else {
    fputs("No image path provided\n", stderr)
    exit(1)
}

let imageURL = URL(fileURLWithPath: imagePath)
guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else {
    fputs("Could not load image: \(imagePath)\n", stderr)
    exit(1)
}

let timestamp = ProcessInfo.processInfo.environment["CHESTNUT_TIMESTAMP"]
    ?? ISO8601DateFormatter().string(from: Date())
let ext = imageURL.pathExtension.lowercased()
let baseName = imageURL.deletingPathExtension().lastPathComponent

let semaphore = DispatchSemaphore(value: 0)
var recognizedLines: [String] = []
var ocrError: Error?

let request = VNRecognizeTextRequest { request, error in
    if let error {
        ocrError = error
    } else if let observations = request.results as? [VNRecognizedTextObservation] {
        recognizedLines = observations.compactMap {
            $0.topCandidates(1).first?.string
        }
    }
    semaphore.signal()
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage)
do {
    try handler.perform([request])
} catch {
    fputs("Vision request failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

semaphore.wait()

if let ocrError {
    fputs("OCR failed: \(ocrError.localizedDescription)\n", stderr)
    exit(1)
}

let text = recognizedLines.joined(separator: "\n")
let attachmentName = "\(baseName).\(ext)"

var parts: [String] = []
parts.append("---")
parts.append("source: ocr")
parts.append("date: \(timestamp)")
parts.append("attachment: \"\(attachmentName)\"")
parts.append("tags: [ocr, image]")
parts.append("---")
parts.append("")
parts.append("# OCR: \(baseName)")
parts.append("")
parts.append("![[\(attachmentName)]]")
parts.append("")

if recognizedLines.isEmpty {
    parts.append("> *No text detected in this image.*")
} else {
    parts.append("## Extracted text")
    parts.append("")
    parts.append(text)
}
parts.append("")

let content = parts.joined(separator: "\n")
let safeBase = baseName
    .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "", options: .regularExpression)
    .prefix(80)
let noteFilename = "OCR \(safeBase).md"
let wordCount = recognizedLines.joined(separator: " ")
    .split(separator: " ").count

let envelope: [String: Any] = [
    "action": "save",
    "content": content,
    "filename": noteFilename,
    "vault": "ask",
    "attachments": [
        ["source": imagePath, "filename": attachmentName]
    ],
    "notify": "\(wordCount) words extracted"
]

guard let json = try? JSONSerialization.data(
    withJSONObject: envelope, options: []
) else {
    fputs("Failed to encode JSON output\n", stderr)
    exit(1)
}

FileHandle.standardOutput.write(json)
