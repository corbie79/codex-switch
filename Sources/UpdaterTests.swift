import Foundation
import CryptoKit

func runUpdateTests() throws {
    func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid update accepted") } catch {}
    }
    precondition(try! Version("0.1.9") < Version("0.1.10"))
    precondition(try! Version("1.0.0") > Version("0.99.99"))
    precondition(try! Version("0.2.0") == Version("0.2.0"))
    rejects { _ = try Version("0.2.0-beta.1") }
    rejects { _ = try Version("99999999999999999999999999999.2.0") }
    let key = Curve25519.Signing.PrivateKey()
    let bytes = Data("archive fixture".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let manifest = UpdateManifest(version: "0.2.0", sha256: hash, size: bytes.count,
        url: UpdateManifest.baseURL + "v0.2.0/Codex-Account-Switcher-0.2.0-macOS-arm64.zip")
    func envelope(_ manifest: UpdateManifest) throws -> Data {
        let data = try JSONEncoder().encode(manifest)
        return try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": key.signature(for: data).base64EncodedString()])
    }
    let signed = try envelope(manifest)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let verified = try UpdateManifest.verified(signed, key: publicKey)
    try verified.validateArchive(bytes)
    rejects { try verified.validateArchive(Data("tampered".utf8)) }
    rejects { _ = try UpdateManifest.verified(signed) } // Test key is not the pinned release key.
    rejects { _ = try UpdateManifest.verified(Data("{}".utf8), key: publicKey) }
    rejects {
        let wrongURL = UpdateManifest(version: "0.2.0", sha256: hash, size: bytes.count, url: "https://example.com/app.zip")
        _ = try UpdateManifest.verified(envelope(wrongURL), key: publicKey)
    }
    for path in ["../outside", "/absolute", "Codex Account Switcher.app/../outside", "other.app/file", "Codex Account Switcher.app/./file"] {
        precondition(!UpdateInstaller.validArchiveEntry(path))
    }
    precondition(UpdateInstaller.validArchiveEntry("Codex Account Switcher.app/Contents/Info.plist"))
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("switch-update-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("installed.app"), staged = root.appendingPathComponent("new.app"), backup = root.appendingPathComponent("backup.app")
    try Data("old".utf8).write(to: target); try Data("new".utf8).write(to: staged)
    rejects { try UpdateInstaller.replace(staged: staged, target: target, backup: backup) { _ in throw Failure(message: "Launch failed") } }
    precondition(try! Data(contentsOf: target) == Data("old".utf8))
    precondition(try! Data(contentsOf: staged) == Data("new".utf8))
    precondition(!fm.fileExists(atPath: backup.path))
    try UpdateInstaller.replace(staged: staged, target: target, backup: backup) { _ in }
    precondition(try! Data(contentsOf: target) == Data("new".utf8))
    precondition(!fm.fileExists(atPath: backup.path))
    rejects { try UpdateInstaller.replace(staged: staged, target: target, backup: backup) { _ in } } // Missing staged file also rolls back.
    precondition(try! Data(contentsOf: target) == Data("new".utf8))
    print("PASS: update versions, signature trust, corrupt downloads, archive paths, replacement and rollback")
}

// Exercises the real release ZIP and replacement against a disposable app copy.
func testUpdateArchive(_ path: String, version: String) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("switch-install-test-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent(UpdateInstaller.bundleName)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    let archive = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = UpdateManifest(version: version, sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(), size: archive.count, url: "unused")
    let work = try UpdateInstaller.prepare(archive: archive, manifest: manifest, target: target)
    try UpdateInstaller.replace(staged: work.appendingPathComponent(UpdateInstaller.bundleName), target: target, backup: work.appendingPathComponent("old.app")) { installed in
        try UpdateInstaller.validateBundle(installed, version: version)
        try UpdateInstaller.command(installed.appendingPathComponent("Contents/MacOS/CodexAccountSwitcher").path, ["--self-test"])
    }
    print("PASS: real release ZIP extracted, validated, installed and executable tested in temporary folder")
}
