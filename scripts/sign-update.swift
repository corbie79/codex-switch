import Foundation
import CryptoKit

let args = CommandLine.arguments
if args.count == 3 && args[1] == "--generate-key" {
    let path = URL(fileURLWithPath: args[2])
    let fm = FileManager.default
    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard !fm.fileExists(atPath: path.path) else { fatalError("Signing key already exists; do not overwrite it") }
    let key = Curve25519.Signing.PrivateKey()
    guard fm.createFile(atPath: path.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else { fatalError("Cannot save key") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    guard args.count == 3, let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let bytes = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else { fatalError("Usage: UPDATE_SIGNING_KEY=… swift scripts/sign-update.swift VERSION ARCHIVE") }
    let version = args[1], archive = URL(fileURLWithPath: args[2])
    guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { fatalError("Invalid version") }
    let data = try Data(contentsOf: archive)
    let manifest: [String: Any] = ["version": version, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count,
        "url": "https://github.com/corbie79/codex-switch/releases/download/v\(version)/\(archive.lastPathComponent)"]
    let payload = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    let envelope: [String: String] = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: archive.deletingLastPathComponent().appendingPathComponent("update.json"))
    print("Signed update manifest for \(version)")
}
