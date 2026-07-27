#!/usr/bin/env swift

import CryptoKit
import Foundation

struct Manifest: Codable {
    let product: String
    let version: String
    let build: Int
    let assetName: String
    let sha256: String
    let minimumSystemVersion: String
    let signature: String
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

guard let version = argument("--version"),
      let buildText = argument("--build"),
      let build = Int(buildText),
      let assetPath = argument("--asset"),
      let privateKeyPath = argument("--private-key"),
      let outputPath = argument("--output") else {
    FileHandle.standardError.write(Data("Missing release manifest arguments.\n".utf8))
    exit(64)
}

let assetURL = URL(fileURLWithPath: assetPath)
let assetName = assetURL.lastPathComponent
let digest = try sha256(of: assetURL)
let minimumSystemVersion = "14.0"
let payload = Data(
    ["KiteShell", version, String(build), assetName, digest, minimumSystemVersion]
        .joined(separator: "\n")
        .utf8
)
let privateKeyData = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
let signature = try privateKey.signature(for: payload).base64EncodedString()
let manifest = Manifest(
    product: "KiteShell",
    version: version,
    build: build,
    assetName: assetName,
    sha256: digest,
    minimumSystemVersion: minimumSystemVersion,
    signature: signature
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print("Created \(outputPath)")
