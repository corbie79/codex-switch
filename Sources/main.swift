import Cocoa
import Security

struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
enum AccountKind: String, Codable, CaseIterable {
    case personal, business, unknown
    var title: String {
        switch self { case .personal: return "퍼스널"; case .business: return "비즈니스"; case .unknown: return "기타 / 미확인" }
    }
    static func from(plan: String) -> AccountKind {
        // Codex also emits this Business SKU in current login tokens.
        if plan.lowercased().hasPrefix("self_serve_business_") { return .business }
        switch plan.lowercased() {
        case "free", "plus", "pro", "go": return .personal
        case "team", "business", "enterprise", "edu": return .business
        default: return .unknown
        }
    }
}
struct Profile: Codable {
    var id: String
    var label: String
    var kind: AccountKind?
}
struct Registration {
    let kind: AccountKind
    let workspace: String?
    func validate(_ identity: Identity) throws {
        if let workspace = workspace, workspace.lowercased() != identity.workspace.lowercased() {
            throw Failure(message: "선택한 워크스페이스와 로그인 결과가 다릅니다. 다시 로그인해 주세요.")
        }
        if kind != .unknown && identity.kind != .unknown && kind != identity.kind {
            throw Failure(message: "\(kind.title) 등록을 선택했지만 \(identity.kind.title)로 로그인되었습니다. 브라우저에서 올바른 워크스페이스를 선택해 주세요.")
        }
    }
}
struct Identity {
    let id: String
    let label: String
    let workspace: String
    let kind: AccountKind
    static func parse(_ data: Data) throws -> Identity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              let tokens = root["tokens"] as? [String:Any],
              let token = tokens["id_token"] as? String,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty else {
            throw Failure(message: "ChatGPT 계정 로그인 정보가 필요합니다. API 키 로그인은 지원하지 않습니다.")
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Failure(message: "로그인 정보 형식이 올바르지 않습니다.") }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let bytes = Data(base64Encoded: body), let claims = try JSONSerialization.jsonObject(with: bytes) as? [String:Any],
              let sub = claims["sub"] as? String, !sub.isEmpty else { throw Failure(message: "계정을 식별할 수 없습니다.") }
        let authClaims = claims["https://api.openai.com/auth"] as? [String:Any] ?? [:]
        if let claimed = authClaims["chatgpt_account_id"] as? String, claimed != account {
            throw Failure(message: "로그인 토큰의 워크스페이스가 일치하지 않습니다.")
        }
        let kind = AccountKind.from(plan: authClaims["chatgpt_plan_type"] as? String ?? "")
        return Identity(id: sub + "|" + account,
                        label: (claims["email"] as? String ?? "ChatGPT") + " · " + String(account.suffix(6)),
                        workspace: account, kind: kind)
    }
}
final class Vault {
    let service = "local.codex-account-switcher.credentials"
    func query(_ id: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:id] }
    func put(_ id: String, _ data: Data) throws {
        let q = query(id)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(message: "키체인 저장 실패 (\(status))") }
    }
    func get(_ id: String) throws -> Data {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(message: "키체인 읽기 실패 (\(status))") }
        return data
    }
    func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(message: "키체인 삭제 실패 (\(status))") }
    }
}
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let fm = FileManager.default
    let vault = Vault()
    let home: URL = {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Account Switcher")
    var profiles: [Profile] = []
    var item: NSStatusItem!
    var busy = false
    var login: Process?
    var loginDirectory: URL?
    var loginTimer: Timer?
    var registration: Registration?
    var restartVS: Bool { get { UserDefaults.standard.bool(forKey: "restartVS") } set { UserDefaults.standard.set(newValue, forKey: "restartVS") } }
    var auth: URL { home.appendingPathComponent("auth.json") }
    var appURL: URL { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? URL(fileURLWithPath: "/Applications/ChatGPT.app") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-account-switcher").count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "person.crop.circle.badge.arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: "Codex 계정 전환") ?? NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Codex 계정 전환")
        item.button?.image?.isTemplate = true
        item.button?.title = " CX"
        item.button?.toolTip = "Codex 계정 전환"
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            if let data = try? Data(contentsOf: directory.appendingPathComponent("profiles.json")) { profiles = try JSONDecoder().decode([Profile].self, from:data) }
            if fm.fileExists(atPath: auth.path) { try capture() }
        } catch { show(error) }
        rebuild()
    }
    func save() throws { try JSONEncoder().encode(profiles).write(to:directory.appendingPathComponent("profiles.json"), options:.atomic) }
    @discardableResult func capture() throws -> Identity {
        let data = try Data(contentsOf:auth); let identity = try Identity.parse(data)
        try vault.put(identity.id, data)
        try remember(identity)
        return identity
    }
    func remember(_ identity: Identity, selected: AccountKind = .unknown) throws {
        let kind = identity.kind == .unknown ? selected : identity.kind
        if let index = profiles.firstIndex(where: { $0.id == identity.id }) {
            profiles[index].label = identity.label
            if kind != .unknown { profiles[index].kind = kind }
        } else { profiles.append(Profile(id: identity.id, label: identity.label, kind: kind)) }
        try save()
    }
    @discardableResult func add(_ menu:NSMenu, _ title:String, _ action:Selector?, _ represented:Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title:title, action:action, keyEquivalent:""); i.target = self; i.representedObject = represented; menu.addItem(i); return i
    }
    func rebuild() {
        let menu = NSMenu(); menu.delegate = self
        menu.autoenablesItems = false
        let current = (try? Data(contentsOf:auth)).flatMap { try? Identity.parse($0) }
        add(menu, busy ? "계정 처리 중…" : "Codex 계정 전환", nil).isEnabled = false
        for kind in AccountKind.allCases {
            let group = profiles.filter { ($0.kind ?? .unknown) == kind }
            if !group.isEmpty {
                add(menu, kind.title, nil).isEnabled = false
                for p in group {
                    let i = add(menu, p.label, #selector(switchAccount(_:)), p.id)
                    i.state = current?.id == p.id ? .on : .off; i.isEnabled = !busy
                }
            }
        }
        menu.addItem(.separator())
        add(menu,"＋ 퍼스널 / 비즈니스 등록…",#selector(addAccount)).isEnabled = !busy
        add(menu,"현재 로그인 계정 저장",#selector(saveCurrent)).isEnabled = !busy
        if login != nil { add(menu,"로그인 취소",#selector(cancelLogin)) }
        let settings = NSMenu(); settings.autoenablesItems = false
        let vs = add(settings,"VS Code도 함께 재실행",#selector(toggleVS)); vs.state = restartVS ? .on : .off; vs.isEnabled = !busy
        add(settings,"등록 계정 삭제…",#selector(removeAccount)).isEnabled = !busy
        let settingsItem = add(menu,"설정",nil); settingsItem.submenu = settings
        add(menu,"사용 안내",#selector(help))
        add(menu,"종료",#selector(quit)).isEnabled = !busy
        item.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        let current = (try? Data(contentsOf:auth)).flatMap { try? Identity.parse($0) }
        for entry in menu.items where entry.representedObject is String {
            entry.state = (entry.representedObject as? String) == current?.id ? .on : .off
        }
    }
    func show(_ error: Error) { alert("작업을 완료하지 못했습니다",error.localizedDescription) }
    func alert(_ title:String,_ message:String) { NSApp.activate(ignoringOtherApps:true); let a=NSAlert(); a.messageText=title; a.informativeText=message; a.runModal() }
    @objc func help() { alert("Codex 계정 전환", "1. ‘퍼스널 / 비즈니스 등록’에서 각각 로그인하고 브라우저에서 해당 워크스페이스를 선택하세요. 같은 이메일도 워크스페이스별로 별도 등록됩니다.\n2. 메뉴에서 계정을 선택하면 Codex를 종료하고 선택한 계정으로 다시 엽니다. 실행 중인 작업은 먼저 마무리하세요.\n3. 필요하면 설정에서 VS Code 재실행도 켜세요. 별도로 실행한 터미널 CLI는 직접 종료해 주세요.\n\n등록 정보는 macOS 키체인에 저장됩니다. Codex의 작업·설정은 공유됩니다. 만료된 계정은 다시 추가해 주세요.") }
    @objc func toggleVS() { restartVS.toggle(); rebuild() }
    @objc func saveCurrent() { do { try capture(); rebuild() } catch { show(error) } }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func removeAccount() {
        guard !profiles.isEmpty else { return }
        let a=NSAlert(); a.messageText="목록에서 삭제할 계정"; a.informativeText="Codex의 현재 로그인은 유지됩니다."; a.addButton(withTitle:"삭제"); a.addButton(withTitle:"취소")
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:360,height:28)); picker.addItems(withTitles:profiles.map(\.label)); a.accessoryView=picker
        NSApp.activate(ignoringOtherApps:true)
        if a.runModal() == .alertFirstButtonReturn { do { let index=picker.indexOfSelectedItem; try vault.delete(profiles[index].id); profiles.remove(at:index); try save(); rebuild() } catch { show(error) } }
    }
    func askRegistration() -> Registration? {
        let a = NSAlert(); a.messageText = "퍼스널 / 비즈니스 등록"
        a.informativeText = "등록할 유형을 선택하고, 브라우저에서 해당 워크스페이스로 로그인하세요. 같은 이메일의 퍼스널과 비즈니스도 각각 등록할 수 있습니다."
        a.addButton(withTitle: "브라우저 로그인"); a.addButton(withTitle: "취소")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: 380, height: 28))
        picker.addItems(withTitles: ["퍼스널", "비즈니스", "자동 감지"])
        let field = NSTextField(frame: NSRect(x: 0, y: 8, width: 380, height: 26))
        field.placeholderString = "워크스페이스 ID (선택, 모르면 비워 두세요)"
        view.addSubview(picker); view.addSubview(field); a.accessoryView = view
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let workspace = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty && UUID(uuidString: workspace) == nil {
            alert("워크스페이스 ID 확인", "워크스페이스 ID는 UUID 형식입니다. 모르면 비워 두고 브라우저에서 선택하세요.")
            return nil
        }
        return Registration(kind: AccountKind.allCases[picker.indexOfSelectedItem], workspace: workspace.isEmpty ? nil : workspace)
    }
    @objc func addAccount() {
        guard !busy, let request = askRegistration() else { return }
        do {
            let temp=directory.appendingPathComponent("login-"+UUID().uuidString)
            try fm.createDirectory(at:temp, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            let p=Process(); p.executableURL=appURL.appendingPathComponent("Contents/Resources/codex")
            p.arguments=["login","-c","cli_auth_credentials_store=\"file\""]
            if let workspace = request.workspace {
                p.arguments! += ["-c", "forced_chatgpt_workspace_id=\"\(workspace)\""]
            }
            registration = request
            var env=ProcessInfo.processInfo.environment; env["CODEX_HOME"]=temp.path; env.removeValue(forKey:"CODEX_ACCESS_TOKEN"); env.removeValue(forKey:"OPENAI_API_KEY"); p.environment=env
            p.standardOutput=FileHandle.nullDevice; p.standardError=FileHandle.nullDevice; p.standardInput=FileHandle.nullDevice
            p.terminationHandler = { [weak self] process in DispatchQueue.main.async { self?.finishedLogin(process) } }
            login=p; loginDirectory=temp; busy=true
            do { try p.run() } catch { login=nil; loginDirectory=nil; busy=false; try? self.fm.removeItem(at:temp); throw error }
            loginTimer=Timer.scheduledTimer(withTimeInterval:300,repeats:false) { [weak self] _ in self?.cancelLogin() }
            rebuild()
        } catch { show(error) }
    }
    func finishedLogin(_ p:Process) {
        guard login === p, let temp=loginDirectory else { return }
        defer { registration=nil; loginTimer?.invalidate(); login=nil; loginDirectory=nil; busy=false; try? fm.removeItem(at:temp); rebuild() }
        do {
            guard p.terminationStatus == 0 else { throw Failure(message:"로그인이 완료되지 않았습니다. 브라우저 로그인을 다시 시도하세요. 다른 Codex 로그인 창이 열려 있다면 먼저 닫아 주세요.") }
            let data=try Data(contentsOf:temp.appendingPathComponent("auth.json")); let identity=try Identity.parse(data)
            try registration?.validate(identity)
            // A separately issued refresh token must not replace the live account's token.
            let live=(try? Data(contentsOf:auth)).flatMap { try? Identity.parse($0) }
            if live?.id == identity.id { let current = try capture(); try remember(current, selected: registration?.kind ?? .unknown) }
            else {
                try vault.put(identity.id,data)
                try remember(identity, selected: registration?.kind ?? .unknown)
            }
            alert("계정 등록 완료", "\((profiles.first { $0.id == identity.id }?.kind ?? .unknown).title) · \(identity.label)\n상단 메뉴에서 이 계정을 선택하면 전환됩니다.")
        } catch { show(error) }
    }
    @objc func cancelLogin() {
        guard let p=login else { return }
        let temp=loginDirectory; login=nil; loginDirectory=nil; loginTimer?.invalidate()
        if p.isRunning { p.terminate() }
        busy=false; rebuild()
        DispatchQueue.global().async { p.waitUntilExit(); if let temp=temp { try? FileManager.default.removeItem(at:temp) } }
    }
    @objc func switchAccount(_ sender:NSMenuItem) {
        guard !busy, let id=sender.representedObject as? String else { return }
        do {
            let data=try vault.get(id); guard try Identity.parse(data).id == id else { throw Failure(message:"저장된 계정 정보가 일치하지 않습니다.") }
            // Save refreshed credentials before and again after the app has fully exited.
            if fm.fileExists(atPath:auth.path) { try capture() }
            busy=true; rebuild()
            var targets=NSRunningApplication.runningApplications(withBundleIdentifier:"com.openai.codex")
            if restartVS { targets += NSRunningApplication.runningApplications(withBundleIdentifier:"com.microsoft.VSCode") }
            for app in targets { _ = app.terminate() }
            waitForExit(targets, id:id, data:data, deadline:Date().addingTimeInterval(25))
        } catch { busy=false; rebuild(); show(error) }
    }
    func waitForExit(_ targets:[NSRunningApplication], id:String, data:Data, deadline:Date) {
        if targets.contains(where:{!$0.isTerminated}) {
            if Date() > deadline { busy=false; rebuild(); alert("전환을 중단했습니다", "앱이 종료되지 않았습니다. 저장 확인 창이나 진행 중인 작업을 확인한 뒤 다시 시도하세요. 로그인 파일은 변경하지 않았습니다."); return }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { self.waitForExit(targets,id:id,data:data,deadline:deadline) }; return
        }
        do {
            let oldData=try? Data(contentsOf:auth)
            let current: Identity? = oldData == nil ? nil : try capture()
            let chosen = current?.id == id ? try vault.get(id) : data
            try writeAuth(chosen)
            let config=NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at:appURL,configuration:config) { _,error in DispatchQueue.main.async {
                if let error=error {
                    do { if let oldData=oldData { try self.writeAuth(oldData) } else { try self.fm.removeItem(at:self.auth) } }
                    catch { self.show(Failure(message:"재실행 및 이전 로그인 복원에 실패했습니다. 현재 로그인 계정을 확인하세요.")) }
                    self.show(error)
                } else if self.restartVS, let vs=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.VSCode") {
                    NSWorkspace.shared.openApplication(at:vs,configuration:NSWorkspace.OpenConfiguration()) { _,e in if let e=e { DispatchQueue.main.async { self.show(e) } } }
                }
                self.busy=false; self.rebuild()
            } }
        } catch { busy=false; rebuild(); show(error) }
    }
    func writeAuth(_ data:Data) throws {
        // Stage with 0600 before atomic replacement, so credentials are never world-readable.
        let staged=home.appendingPathComponent(".switcher-"+UUID().uuidString)
        guard fm.createFile(atPath:staged.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw Failure(message:"로그인 파일을 준비할 수 없습니다.") }
        defer { try? fm.removeItem(at:staged) }
        guard rename(staged.path,auth.path) == 0 else { throw Failure(message:"로그인 파일을 교체할 수 없습니다.") }
    }
}
if CommandLine.arguments.contains("--self-test") {
    func fixture(_ sub: String, _ account: String, _ plan: String, claimAccount: String? = nil) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "email": "test@example.invalid",
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan, "chatgpt_account_id": claimAccount ?? account]])
        let jwt = "e30." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".test"
        return try! JSONSerialization.data(withJSONObject: ["tokens": ["id_token": jwt, "refresh_token": "fake", "access_token": "fake", "account_id": account]])
    }
    func rejects(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid input accepted") } catch {}
    }
    let personal = try! Identity.parse(fixture("same-user", "personal-workspace", "plus"))
    let business = try! Identity.parse(fixture("same-user", "business-workspace", "team"))
    precondition(personal.id != business.id && personal.kind == .personal && business.kind == .business)
    precondition(try! Identity.parse(fixture("other-user", "business-workspace", "business")).id != business.id)
    for plan in ["business", "team", "enterprise", "edu", "self_serve_business_prolite"] { precondition(AccountKind.from(plan: plan) == .business) }
    for plan in ["free", "plus", "pro", "go"] { precondition(AccountKind.from(plan: plan) == .personal) }
    rejects { _ = try Identity.parse(Data("{}".utf8)) }
    rejects { _ = try Identity.parse(fixture("a", "w", "plus", claimAccount: "wrong")) }
    rejects { try Registration(kind: .business, workspace: nil).validate(personal) }
    rejects { try Registration(kind: .unknown, workspace: "wrong").validate(business) }
    try! Registration(kind: .personal, workspace: "personal-workspace").validate(personal)
    try! Registration(kind: .business, workspace: nil).validate(business)
    let legacy = Data("[{\"id\":\"legacy\",\"label\":\"Existing account\"}]".utf8)
    precondition(try! JSONDecoder().decode([Profile].self, from: legacy)[0].kind == nil)
    if CommandLine.arguments.contains("--keychain-test") {
        let id = "self-test-" + UUID().uuidString; let vault = Vault()
        do {
            try vault.put(id, Data("one".utf8)); precondition(try! vault.get(id) == Data("one".utf8))
            try vault.put(id, Data("two".utf8)); precondition(try! vault.get(id) == Data("two".utf8))
            try vault.delete(id)
        } catch { try? vault.delete(id); fatalError("Keychain test failed: \(error)") }
    }
    print("PASS: personal/business isolation, plan classification, workspace validation, legacy profiles")
} else {
    let app=NSApplication.shared; let delegate=App(); app.delegate=delegate; app.run()
}
