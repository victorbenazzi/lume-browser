import AppKit

final class LumeApplicationDelegate: NSObject, NSApplicationDelegate {
    let store: BrowserStore
    let controller: BrowserWindowController
    private var quitObserver: NSObjectProtocol?

    init(engine: CEFEngine, dataDirectory: URL) {
        store = BrowserStore(engine: engine, dataDirectory: dataDirectory)
        controller = BrowserWindowController(store: store)
        engine.setDialogWindow(controller.window)
        super.init()
        controller.installMenus()
        quitObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("LumeWillQuit"),
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.store.shutdown()
        }
    }

    func show() {
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

let environment = ProcessInfo.processInfo.environment
let profileDirectory: URL
if let override = environment["LUME_PROFILE_DIR"], override.hasPrefix("/") {
    profileDirectory = URL(fileURLWithPath: override, isDirectory: true)
} else {
    profileDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Lume", isDirectory: true)
}
do {
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
} catch {
    fputs("Lume could not create its profile: \(error.localizedDescription)\n", stderr)
    exit(1)
}

var appDelegate: LumeApplicationDelegate?
var smokeCheck: SmokeCheck?
var reliabilityCheck: ReliabilityCheck?
var smokeExitCode: Int32 = 0
let result = LBRunBrowser(CommandLine.argc, CommandLine.unsafeArgv,
                         profileDirectory.appendingPathComponent("Chromium").path) {
    let engine = CEFEngine()
    let delegate = LumeApplicationDelegate(engine: engine, dataDirectory: profileDirectory)
    appDelegate = delegate
    NSApp.delegate = delegate
    delegate.show()
    if CommandLine.arguments.contains("--reliability-test"),
       let baseURL = environment["LUME_TEST_URL"], baseURL.hasPrefix("http://127.0.0.1:"),
       let phase = environment["LUME_TEST_PHASE"] {
        let check = ReliabilityCheck(store: delegate.store, engine: engine, baseURL: baseURL, phase: phase)
        check.completion = { passed in smokeExitCode = passed ? 0 : 1 }
        reliabilityCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check.start() }
    }
    if CommandLine.arguments.contains("--smoke-test"),
       let baseURL = environment["LUME_TEST_URL"], baseURL.hasPrefix("http://127.0.0.1:") {
        let check = SmokeCheck(store: delegate.store, engine: engine, baseURL: baseURL)
        check.completion = { passed in smokeExitCode = passed ? 0 : 1 }
        smokeCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check.start() }
    }
}
exit(result == 0 ? smokeExitCode : result)
