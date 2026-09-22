import Cocoa

/// Isolated launch configuration. Existing windows and credentials are never transferred.
/// Each slot must obtain its own login session before concurrent use is supported.
enum IsolatedSlot: String, Codable, CaseIterable {
    case personal, business
    var title: String { self == .personal ? "퍼스널" : "비즈니스" }
}

struct IsolatedLaunchPlan: Codable {
    let slot: IsolatedSlot
    let profileRoot: URL
    let codexHome: URL
    let desktopData: URL
    let executable: String
    let arguments: [String]
    let requiresFreshLogin: Bool

    init(slot: IsolatedSlot, storageRoot: URL, app: URL) throws {
        guard storageRoot.isFileURL, app.isFileURL, app.pathExtension == "app" else {
            throw Failure(message: "독립 실행 경로가 올바르지 않습니다.")
        }
        self.slot = slot
        profileRoot = storageRoot.standardizedFileURL.appendingPathComponent(slot.rawValue, isDirectory: true)
        codexHome = profileRoot.appendingPathComponent("codex", isDirectory: true)
        desktopData = profileRoot.appendingPathComponent("desktop", isDirectory: true)
        executable = "/usr/bin/open"
        arguments = ["-n", "--env", "CODEX_HOME=" + codexHome.path,
                     "--env", "CODEX_ELECTRON_USER_DATA_PATH=" + desktopData.path,
                     app.path, "--args", "--user-data-dir=" + desktopData.path]
        requiresFreshLogin = true
    }

    /// The launcher uses this instead of inheriting tokens, app RPC pipes,
    /// or developer overrides from the current Codex process.
    static func launchEnvironment(from original: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        return original.filter { allowed.contains($0.key) }
    }

    /// Creates a fresh, empty profile, never copies auth.json or session databases.
    /// Called only on first launch; the dry-run CLI does not call this method.
    /// Refuses all existing slots so preparation cannot overwrite an active profile.
    func prepareFreshDirectories() throws {
        let fm = FileManager.default
        try rejectSymlinks(profileRoot)
        guard !fm.fileExists(atPath: profileRoot.path) else {
            throw Failure(message: "이미 존재하는 독립 프로필은 변경하지 않습니다.")
        }
        try fm.createDirectory(at: profileRoot.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Atomic directory creation prevents two preparations claiming the same slot.
        guard mkdir(profileRoot.path, 0o700) == 0 else { throw Failure(message: "독립 프로필을 만들 수 없습니다.") }
        do {
            try fm.createDirectory(at: codexHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: desktopData, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let config = Data("cli_auth_credentials_store = \"file\"\n".utf8)
            guard fm.createFile(atPath: codexHome.appendingPathComponent("config.toml").path, contents: config, attributes: [.posixPermissions: 0o600]) else {
                throw Failure(message: "독립 프로필 설정을 저장할 수 없습니다.")
            }
        } catch { try? fm.removeItem(at: profileRoot); throw error }
    }
    func rejectSymlinks(_ path: URL) throws {
        var ancestor = path
        while ancestor.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw Failure(message: "독립 프로필 경로에는 심볼릭 링크를 사용할 수 없습니다.")
            }
            ancestor.deleteLastPathComponent()
        }
    }
    func ensureDirectories() throws {
        let fm = FileManager.default
        try rejectSymlinks(profileRoot)
        if !fm.fileExists(atPath: profileRoot.path) { try prepareFreshDirectories(); return }
        for directory in [profileRoot, codexHome, desktopData] {
            try rejectSymlinks(directory)
            let attrs = try fm.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw Failure(message: "독립 프로필 폴더의 형식 또는 접근 권한을 확인해 주세요.")
            }
        }
        try rejectSymlinks(codexHome.appendingPathComponent("config.toml"))
        // Never rewrite an existing profile's configuration, authentication, or history.
    }

}


enum IsolatedRuntime {
    static func processCommand(_ pid: pid_t) throws -> String {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else {
            throw Failure(message: "실행 중인 Codex를 확인할 수 없어 전체 전환을 중단했습니다.")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func safeForGlobalSwitch(commands: [String?]) -> Bool {
        commands.count <= 1 && commands.allSatisfy { command in
            guard let command = command, !command.isEmpty else { return false }
            return !command.contains("--user-data-dir")
        }
    }
    static func globalSwitchTargets() throws -> [NSRunningApplication] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
        let commands = apps.map { try? processCommand($0.processIdentifier) }
        guard safeForGlobalSwitch(commands: commands) else {
            throw Failure(message: "독립 실행 창 또는 여러 Codex 인스턴스가 열려 있어 전체 계정 전환을 차단했습니다. 독립 창은 각 창에서 로그인 계정을 관리하거나, 먼저 독립 앱을 종료해 주세요.")
        }
        return apps
    }
    static func existingInstance(for plan: IsolatedLaunchPlan) throws -> NSRunningApplication? {
        let marker = "--user-data-dir=" + plan.desktopData.path
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex") where !app.isTerminated {
            let command = try processCommand(app.processIdentifier)
            if command.hasSuffix(marker) || command.contains(marker + " ") { return app }
        }
        return nil
    }
    static func launch(_ plan: IsolatedLaunchPlan, completion: @escaping (Error?) -> Void) throws {
        try plan.ensureDirectories()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: plan.executable); p.arguments = plan.arguments
        p.environment = IsolatedLaunchPlan.launchEnvironment(from: ProcessInfo.processInfo.environment)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { process in
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0 ? nil : Failure(message: "독립 Codex 실행 요청에 실패했습니다. 설치된 Codex 버전을 확인해 주세요."))
            }
        }
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
    }
}

func runIsolatedProfileTests() throws {
    let fm = FileManager.default
    // Foundation preserves the /var alias even after resolvingSymlinksInPath on macOS.
    let temporaryPath = fm.temporaryDirectory.path
    let canonicalTemp = URL(fileURLWithPath: temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath)
    let root = canonicalTemp.appendingPathComponent("isolated-plan-test-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let app = URL(fileURLWithPath: "/Applications/Test App.app")
    let personal = try IsolatedLaunchPlan(slot: .personal, storageRoot: root, app: app)
    let business = try IsolatedLaunchPlan(slot: .business, storageRoot: root, app: app)
    precondition(personal.codexHome != business.codexHome && personal.desktopData != business.desktopData)
    precondition(!fm.fileExists(atPath: root.path)) // Constructing a plan is strictly read-only.
    precondition(personal.arguments.contains(app.path)) // Space is kept inside one argument.
    precondition(personal.arguments.contains("CODEX_HOME=" + personal.codexHome.path))
    precondition(personal.arguments.contains("CODEX_ELECTRON_USER_DATA_PATH=" + personal.desktopData.path))
    let clean = IsolatedLaunchPlan.launchEnvironment(from: ["HOME": "/test", "PATH": "/usr/bin", "CODEX_HOME": "/active", "CODEX_APP_TOOLS_PIPE_PATH": "private", "OPENAI_API_KEY": "synthetic", "CODEX_ACCESS_TOKEN": "synthetic", "NODE_OPTIONS": "unsafe"])
    precondition(clean == ["HOME": "/test", "PATH": "/usr/bin"])
    try personal.prepareFreshDirectories(); try business.prepareFreshDirectories()
    precondition(!fm.fileExists(atPath: personal.codexHome.appendingPathComponent("auth.json").path))
    precondition(!fm.fileExists(atPath: business.codexHome.appendingPathComponent("auth.json").path))
    try personal.ensureDirectories() // Reopening preserves the profile.
    precondition(IsolatedRuntime.safeForGlobalSwitch(commands: []))
    precondition(IsolatedRuntime.safeForGlobalSwitch(commands: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]))
    precondition(!IsolatedRuntime.safeForGlobalSwitch(commands: ["main", "second"]))
    precondition(!IsolatedRuntime.safeForGlobalSwitch(commands: [nil]))
    precondition(!IsolatedRuntime.safeForGlobalSwitch(commands: ["ChatGPT --user-data-dir=/profile/desktop"]))
    let sentinel = personal.codexHome.appendingPathComponent("do-not-overwrite")
    try Data("existing".utf8).write(to: sentinel)
    do { try personal.prepareFreshDirectories(); fatalError("Existing profile overwritten") } catch {}
    try personal.ensureDirectories()
    precondition(try! Data(contentsOf: sentinel) == Data("existing".utf8))
    for directory in [personal.profileRoot, personal.codexHome, personal.desktopData, business.codexHome] {
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    let linkedRoot = root.appendingPathComponent("link")
    try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: personal.profileRoot)
    let linkedPlan = try IsolatedLaunchPlan(slot: .business, storageRoot: linkedRoot, app: app)
    do { try linkedPlan.prepareFreshDirectories(); fatalError("Symlink accepted") } catch {}
    print("PASS: isolated launch plans, separate stores, environment isolation, fresh profiles, overwrite and symlink protection")
}
