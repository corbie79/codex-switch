import Cocoa
import CryptoKit

struct Version: Comparable {
    let parts: [Int]
    init(_ value: String) throws {
        guard value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw Failure(message: "지원하지 않는 업데이트 버전입니다.")
        }
        let parsed = value.split(separator: ".").compactMap { Int($0) }
        guard parsed.count == 3 else { throw Failure(message: "잘못된 버전입니다.") }
        parts = parsed
    }
    static func < (lhs: Version, rhs: Version) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
struct UpdateManifest: Codable {
    let version: String
    let sha256: String
    let size: Int
    let url: String
    static let publicKey = "oVxAeZpB8GtBtmthXNgQjJGTOsMTgRTm31Xd/w0hIdo="
    static let baseURL = "https://github.com/corbie79/codex-switch/releases/download/"
    static func verified(_ data: Data, key: String = publicKey) throws -> UpdateManifest {
        struct Envelope: Decodable { let payload: String; let signature: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature),
              let keyData = Data(base64Encoded: key),
              try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: payload) else {
            throw Failure(message: "업데이트 서명을 확인할 수 없습니다. 설치를 중단했습니다.")
        }
        let result = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        _ = try Version(result.version)
        guard result.url == baseURL + "v\(result.version)/Codex-Account-Switcher-\(result.version)-macOS-arm64.zip",
              result.size > 0, result.size < 50_000_000,
              result.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw Failure(message: "업데이트 파일 정보가 올바르지 않습니다.")
        }
        return result
    }
    func validateArchive(_ data: Data) throws {
        guard data.count == size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw Failure(message: "업데이트 파일이 손상되었습니다. 설치를 중단했습니다.")
        }
    }
}

enum UpdateInstaller {
    static let bundleName = "Codex Account Switcher.app"
    static let errorFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Account Switcher/update-error.txt")
    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: "업데이트 파일 검사 또는 설치 작업에 실패했습니다.") }
        return output
    }
    static func validArchiveEntry(_ entry: String) -> Bool {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        return !entry.hasPrefix("/") && parts.first == Substring(bundleName) && !parts.contains("..") && !parts.contains(".") && !entry.contains("\\")
    }
    static func prepare(archive: Data, manifest: UpdateManifest, target: URL) throws -> URL {
        try manifest.validateArchive(archive)
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: parent.path) else {
            throw Failure(message: "앱 폴더에 쓰기 권한이 없습니다. 앱을 사용자 응용 프로그램 폴더(~/Applications)로 옮긴 뒤 다시 시도하세요.")
        }
        let work = parent.appendingPathComponent(".codex-switch-update-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let zip = work.appendingPathComponent("update.zip")
            try archive.write(to: zip)
            let entries = try command("/usr/bin/unzip", ["-Z1", zip.path])
            let paths = String(decoding: entries, as: UTF8.self).split(separator: "\n").map(String.init)
            guard !paths.isEmpty, paths.allSatisfy(validArchiveEntry) else { throw Failure(message: "업데이트 ZIP에 허용되지 않은 경로가 있습니다.") }
            try command("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let staged = work.appendingPathComponent(bundleName)
            // This app has no framework symlinks; reject all links in a downloaded bundle.
            if let entries = fm.enumerator(at: staged, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in entries {
                    if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        throw Failure(message: "업데이트 앱에 허용되지 않은 링크가 있습니다.")
                    }
                }
            }
            try validateBundle(staged, version: manifest.version)
            return work
        } catch { try? fm.removeItem(at: work); throw error }
    }
    static func validateBundle(_ url: URL, version: String? = nil) throws {
        let plist = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "local.codex-account-switcher",
              info?["CFBundleExecutable"] as? String == "CodexAccountSwitcher",
              version == nil || info?["CFBundleShortVersionString"] as? String == version else {
            throw Failure(message: "다운로드한 앱의 종류 또는 버전이 다릅니다.")
        }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        let arch = try command("/usr/bin/lipo", ["-archs", url.appendingPathComponent("Contents/MacOS/CodexAccountSwitcher").path])
        guard String(decoding: arch, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
            throw Failure(message: "Apple Silicon 전용 업데이트가 아닙니다.")
        }
    }
    // Separate transaction so rollback can be tested without changing the installed application.
    static func replace(staged: URL, target: URL, backup: URL, launch: (URL) throws -> Void) throws {
        let fm = FileManager.default
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
            try launch(target)
        } catch {
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: staged) }
            try fm.moveItem(at: backup, to: target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }
    static func runHelper(work: URL, target: URL, parentPID: Int32) {
        let fm = FileManager.default
        let staged = work.appendingPathComponent(bundleName)
        do {
            guard work.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL,
                  work.lastPathComponent.hasPrefix(".codex-switch-update-"), parentPID > 1 else { throw Failure(message: "잘못된 설치 경로입니다.") }
            try validateBundle(staged)
            for _ in 0..<120 {
                if kill(parentPID, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard kill(parentPID, 0) != 0 else { throw Failure(message: "이전 앱이 종료되지 않아 업데이트를 중단했습니다.") }
            try replace(staged: staged, target: target, backup: work.appendingPathComponent("previous.app")) { url in
                try command("/usr/bin/open", ["-n", url.path])
            }
            try? fm.removeItem(at: work)
        } catch {
            try? fm.createDirectory(at: errorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(error.localizedDescription.utf8).write(to: errorFile, options: .atomic)
            // Keep staging/backup for recovery if rollback itself failed.
            if kill(parentPID, 0) != 0 { _ = try? command("/usr/bin/open", ["-n", target.path]) }
        }
    }
}

final class Updater {
    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset]
    }
    static let releasesURL = URL(string: "https://github.com/corbie79/codex-switch/releases/latest")!
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Codex-Account-Switcher", forHTTPHeaderField: "User-Agent")
        let (location, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "GitHub 업데이트 서버에 연결하지 못했습니다. 잠시 후 다시 확인해 주세요.")
        }
        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw Failure(message: "업데이트 응답이 허용된 크기를 초과했습니다.") }
        return try Data(contentsOf: location)
    }
    static func latest(current: String) async throws -> UpdateManifest? {
        let data = try await fetch(URL(string: "https://api.github.com/repos/corbie79/codex-switch/releases/latest")!, limit: 1_000_000)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard try Version(version) > Version(current) else { return nil }
        let expected = UpdateManifest.baseURL + "v\(version)/update.json"
        guard release.assets.contains(where: { $0.name == "update.json" && $0.browser_download_url == expected }) else {
            throw Failure(message: "새 버전에 자동 업데이트 파일이 아직 없습니다. GitHub 릴리스 페이지를 확인해 주세요.")
        }
        let manifest = try UpdateManifest.verified(await fetch(URL(string: expected)!, limit: 16_384))
        guard manifest.version == version else { throw Failure(message: "릴리스 버전과 업데이트 서명이 일치하지 않습니다.") }
        return manifest
    }
    static func stage(_ manifest: UpdateManifest, target: URL) async throws -> URL {
        let data = try await fetch(URL(string: manifest.url)!, limit: 50_000_000)
        return try UpdateInstaller.prepare(archive: data, manifest: manifest, target: target)
    }
    static func launchHelper(work: URL, target: URL) throws {
        let fm = FileManager.default
        let helper = work.appendingPathComponent("installer")
        guard let executable = Bundle.main.executableURL else { throw Failure(message: "설치 도우미를 준비할 수 없습니다.") }
        try fm.copyItem(at: executable, to: helper)
        let process = Process(); process.executableURL = helper
        process.arguments = ["--apply-update", work.path, target.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
