import Cocoa
import CryptoKit
struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/isolation-smoke/profiles-" + UUID().uuidString)
let auth = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
let authBefore = try Data(contentsOf: auth)
let originals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
var launched: [NSRunningApplication] = []
func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
var passed = false
do {
    for slot in IsolatedSlot.allCases {
        let plan = try IsolatedLaunchPlan(slot: slot, storageRoot: root, app: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        var finished = false; var failure: Error?
        try IsolatedRuntime.launch(plan) { error in failure = error; finished = true }
        let deadline = Date().addingTimeInterval(35)
        while !finished && Date() < deadline { spin(0.2) }
        if let error = failure { throw error }
        guard finished else { throw Failure(message: "Launch request timed out") }
        var app: NSRunningApplication?
        while Date() < deadline {
            app = try IsolatedRuntime.existingInstance(for: plan)
            if app != nil { break }; spin(0.5)
        }
        guard let app = app, !originals.contains(where: { $0.processIdentifier == app.processIdentifier }) else { throw Failure(message: "No distinct instance found") }
        launched.append(app)
        print("Distinct \(slot.rawValue) process verified")
    }
    spin(8)
    guard launched.count == 2, launched[0].processIdentifier != launched[1].processIdentifier,
          launched.allSatisfy({ !$0.isTerminated }), originals.allSatisfy({ !$0.isTerminated }) else { throw Failure(message: "Instances did not stay alive") }
    guard try Data(contentsOf: auth) == authBefore else { throw Failure(message: "Original credentials changed") }
    do { _ = try IsolatedRuntime.globalSwitchTargets(); throw Failure(message: "Global switch was not blocked") }
    catch let error as Failure {
        guard error.message.contains("전체 계정 전환을 차단") else { throw error }
    }
    for slot in IsolatedSlot.allCases {
        let plan = try IsolatedLaunchPlan(slot: slot, storageRoot: root, app: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        guard let entries = try? fm.contentsOfDirectory(atPath: plan.desktopData.path), !entries.isEmpty else { throw Failure(message: "No independent desktop data") }
        print("\(slot.rawValue): separate desktop data created; auth file exists: \(fm.fileExists(atPath: plan.codexHome.appendingPathComponent("auth.json").path))")
    }
    passed = true
    print("PASS: two isolated processes alive; original process and credentials unchanged; global switching blocked")
} catch { print("FAIL: \(error.localizedDescription)") }
// Only stop the two exact instances created by this test; never signal pre-existing apps.
for app in launched where !app.isTerminated { _ = app.terminate() }
let deadline = Date().addingTimeInterval(20)
while launched.contains(where: { !$0.isTerminated }) && Date() < deadline { spin(0.25) }
let stopped = launched.allSatisfy { $0.isTerminated }
print("Temporary instances stopped:", stopped)
if stopped { try? fm.removeItem(at: root) }
exit(passed && stopped ? 0 : 1)
