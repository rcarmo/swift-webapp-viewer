import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var windows: [BrowserWindowController] = []
    private var blankWindows: [StartupWindowController] = []
    private var pendingURLs: [URL] = []
    private var userScriptPreferencesWindowController: UserScriptPreferencesWindowController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSRegisterServicesProvider(self, "WebAppViewer")
        NSUpdateDynamicServices()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        if pendingURLs.isEmpty {
            openStartupDestination()
        } else {
            pendingURLs.forEach(openWindow(for:))
            pendingURLs.removeAll()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:))
        open(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func paste(_ sender: Any?) {
        traceStartupFlow("Paste action invoked")
        if activeStartupWindow()?.pasteFromGeneralPasteboard() == true {
            traceStartupFlow("Paste handled by startup window")
            return
        }

        traceStartupFlow("Paste forwarded to NSText responder chain")
        _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    func openWindow(for url: URL) {
        traceStartupFlow("openWindow begin url=\(url.absoluteString)")
        let controller = BrowserWindowController(url: url)
        windows.append(controller)
        traceStartupFlow("openWindow appended controller count=\(windows.count)")
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.updateBrowserChromeForCurrentMouseLocation()
        NSApp.activate(ignoringOtherApps: true)
        traceStartupFlow("openWindow finished key=\(controller.window?.isKeyWindow == true)")
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        terminateIfNoWindowsRemain()
    }

    private func activeBrowserWindow() -> BrowserWindowController? {
        windows.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isMainWindow == true }
            ?? windows.last
    }

    private func activeStartupWindow() -> StartupWindowController? {
        blankWindows.first { $0.window === NSApp.keyWindow }
            ?? blankWindows.first { $0.window === NSApp.mainWindow }
            ?? blankWindows.last
    }

    private func open(_ urls: [URL]) {
        let normalizedURLs = urls.compactMap(URLNormalizer.url(from:))
        guard !normalizedURLs.isEmpty else { return }

        if NSApp.isRunning {
            normalizedURLs.forEach(openWindow(for:))
        } else {
            pendingURLs.append(contentsOf: normalizedURLs)
        }
    }

    private func openStartupDestination() {
        if let url = AppConfig.defaultURL {
            openWindow(for: url)
        } else {
            openBlankWindow()
        }
    }

    private func openBlankWindow() {
        traceStartupFlow("openBlankWindow begin")
        let controller = StartupWindowController { [weak self] url in
            self?.traceStartupFlow("startup onURL received \(url.absoluteString)")
            self?.openWindow(for: url)
            self?.closeActiveStartupWindowAfterURLIntake()
        }
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.blankWindowDidClose(controller)
        }

        blankWindows.append(controller)
        traceStartupFlow("openBlankWindow appended startup count=\(blankWindows.count)")
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        traceStartupFlow("openBlankWindow finished key=\(controller.window?.isKeyWindow == true)")
    }

    private func closeActiveStartupWindowAfterURLIntake() {
        guard let controller = activeStartupWindow() else {
            traceStartupFlow("closeActiveStartupWindowAfterURLIntake no active startup window")
            return
        }
        traceStartupFlow("closeActiveStartupWindowAfterURLIntake closing startup window")
        controller.close()
    }

    private func blankWindowDidClose(_ controller: StartupWindowController) {
        blankWindows.removeAll { $0 === controller }
        traceStartupFlow("blankWindowDidClose remaining startup count=\(blankWindows.count)")
        terminateIfNoWindowsRemain()
    }

    private func terminateIfNoWindowsRemain() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.windows.isEmpty,
                  self.blankWindows.isEmpty else {
                self?.traceStartupFlow("terminateIfNoWindowsRemain skipped browser=\(self?.windows.count ?? -1) startup=\(self?.blankWindows.count ?? -1)")
                return
            }

            self.traceStartupFlow("terminateIfNoWindowsRemain terminating app")
            NSApp.terminate(nil)
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLNormalizer.url(from: rawURL) else {
            return
        }

        openWindow(for: url)
    }

    @objc func openURLService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let url = PasteboardURLReader.url(from: pasteboard, context: "services-open-url") else {
            error.pointee = "No URL was found on the pasteboard." as NSString
            return
        }

        openWindow(for: url)
    }

    @objc private func newWindow(_ sender: Any?) {
        if let url = AppConfig.defaultURL ?? activeBrowserWindow()?.appHomeURL {
            openWindow(for: url)
        } else {
            openBlankWindow()
        }
    }

    @objc private func openLocation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open Location"
        alert.informativeText = "Enter a web address to open in a new app window."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        textField.stringValue = AppConfig.defaultURL?.absoluteString ?? ""
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URLNormalizer.url(from: textField.stringValue) else {
            return
        }

        openWindow(for: url)
    }

    @objc private func reloadPage(_ sender: Any?) {
        activeBrowserWindow()?.reload()
    }

    @objc private func zoomInPage(_ sender: Any?) {
        activeBrowserWindow()?.zoomIn()
    }

    @objc private func zoomOutPage(_ sender: Any?) {
        activeBrowserWindow()?.zoomOut()
    }

    @objc private func resetPageZoom(_ sender: Any?) {
        activeBrowserWindow()?.resetZoom()
    }

    @objc private func showWebInspector(_ sender: Any?) {
        activeBrowserWindow()?.showWebInspector()
    }

    @objc private func showUserScriptPreferences(_ sender: Any?) {
        if userScriptPreferencesWindowController == nil {
            userScriptPreferencesWindowController = UserScriptPreferencesWindowController()
        }
        userScriptPreferencesWindowController?.show()
    }

    @objc private func installURLAsApp(_ sender: Any?) {
        let activeWindow = activeBrowserWindow()
        guard let url = promptForAppInstallURL() else { return }

        Task { @MainActor [weak self, activeWindow] in
            let livePageSnapshot = await activeWindow?.livePageSnapshot(for: url)
            let metadata = await WebAppInstaller.metadata(
                for: url,
                livePageSnapshot: livePageSnapshot
            )

            self?.installWebApp(
                url: url,
                activeWindow: activeWindow,
                metadata: metadata
            )
        }
    }

    private func promptForAppInstallURL() -> URL? {
        let activeWindow = activeBrowserWindow()
        let suggestedURL = activeWindow?.currentURL ?? AppConfig.defaultURL
        return WebAppInstallURLDialog(suggestedURL: suggestedURL).run()
    }

    private func installWebApp(
        url: URL,
        activeWindow: BrowserWindowController?,
        metadata: WebAppInstallMetadata
    ) {
        let dialog = WebAppInstallDialog(
            url: url,
            suggestedName: activeWindow?.suggestedAppName,
            metadata: metadata
        )
        guard let plan = dialog.run() else { return }

        let fileManager = FileManager.default
        var shouldReplace = false

        if fileManager.fileExists(atPath: plan.destinationURL.path) {
            shouldReplace = shouldReplaceInstalledApp(named: plan.name, at: plan.destinationURL)
            guard shouldReplace else { return }
        }

        do {
            try WebAppInstaller.install(plan, replacingExisting: shouldReplace)
            WebAppInstaller.launch(plan.destinationURL)
        } catch {
            showInstallError(error)
        }
    }

    private func shouldReplaceInstalledApp(named name: String, at url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(name) already exists"
        alert.informativeText = "Replace the app in \(url.deletingLastPathComponent().path)?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showInstallError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not install the web app"
        alert.runModal()
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Preferences...",
            action: #selector(AppDelegate.showUserScriptPreferences(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(AppConfig.displayName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(AppConfig.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Window",
            action: #selector(AppDelegate.newWindow(_:)),
            keyEquivalent: "n"
        )
        fileMenu.addItem(
            withTitle: "Open Location...",
            action: #selector(AppDelegate.openLocation(_:)),
            keyEquivalent: "l"
        )
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Install URL as App...",
            action: #selector(AppDelegate.installURLAsApp(_:)),
            keyEquivalent: "i"
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        let pasteItem = editMenu.addItem(
            withTitle: "Paste",
            action: #selector(AppDelegate.paste(_:)),
            keyEquivalent: "v"
        )
        pasteItem.target = self
        editMenu.addItem(
            withTitle: "Delete",
            action: #selector(NSText.delete(_:)),
            keyEquivalent: ""
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Reload Page",
            action: #selector(AppDelegate.reloadPage(_:)),
            keyEquivalent: "r"
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Zoom In",
            action: #selector(AppDelegate.zoomInPage(_:)),
            keyEquivalent: "+"
        )
        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(AppDelegate.zoomOutPage(_:)),
            keyEquivalent: "-"
        )
        viewMenu.addItem(
            withTitle: "Actual Size",
            action: #selector(AppDelegate.resetPageZoom(_:)),
            keyEquivalent: "0"
        )
        viewMenu.addItem(.separator())
        let inspectorItem = viewMenu.addItem(
            withTitle: "Show Web Inspector",
            action: #selector(AppDelegate.showWebInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.zoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func traceStartupFlow(_ message: String) {
        let defaults = UserDefaults.standard
        let isEnabled = defaults.object(forKey: "WebAppViewerTraceURLIntake") as? Bool ?? true
        guard isEnabled else { return }

        let line = "[StartupFlow] \(message)"
        NSLog("%@", line)

        let logURL = URL(fileURLWithPath: "/tmp/WebAppViewer-urlintake.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: data)
            return
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? fileHandle.close() }
        _ = try? fileHandle.seekToEnd()
        try? fileHandle.write(contentsOf: data)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
