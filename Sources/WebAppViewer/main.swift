import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

private enum AppConfig {
    static let displayName = "Web App Viewer"
    static let customURLScheme = "webappviewer"

    static var defaultURL: URL? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "DefaultWebAppURL") as? String,
           let url = URLNormalizer.url(from: value) {
            return url
        }

        return nil
    }
}

private enum URLNormalizer {
    static func url(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), isOpenableWebURL(url) {
            return url
        }

        if !trimmed.contains("://"),
           let url = URL(string: "https://\(trimmed)"),
           isOpenableWebURL(url) {
            return url
        }

        return nil
    }

    static func url(from incomingURL: URL) -> URL? {
        if incomingURL.scheme == AppConfig.customURLScheme {
            return wrappedURL(from: incomingURL)
        }

        if isOpenableWebURL(incomingURL) {
            return incomingURL
        }

        if incomingURL.isFileURL {
            return urlFromFile(at: incomingURL)
        }

        return nil
    }

    private static func wrappedURL(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open",
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }

        return self.url(from: value)
    }

    private static func isOpenableWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func urlFromFile(at fileURL: URL) -> URL? {
        if fileURL.pathExtension.lowercased() == "webloc" {
            return webLocationURL(from: fileURL)
        }

        if let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .url) || type.conforms(to: .plainText) {
            return textURL(from: fileURL)
        }

        return nil
    }

    private static func webLocationURL(from fileURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: fileURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              let value = dictionary["URL"] as? String else {
            return nil
        }

        return url(from: value)
    }

    private static func textURL(from fileURL: URL) -> URL? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return url(from: value)
    }
}

private enum PasteboardURLReader {
    static func url(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.compactMap(URLNormalizer.url(from:)).first {
            return url
        }

        if let rawURL = pasteboard.string(forType: .URL),
           let url = URLNormalizer.url(from: rawURL) {
            return url
        }

        if let string = pasteboard.string(forType: .string),
           let url = URLNormalizer.url(from: string) {
            return url
        }

        return nil
    }
}

final class WindowDragStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class MouseHoverTrackingView: NSView {
    var onMouseHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let window else {
            onMouseHoverChanged?(false)
            return
        }

        onMouseHoverChanged?(window.frame.contains(NSEvent.mouseLocation))
    }
}

final class StartupDropView: NSView {
    private let onURL: (URL) -> Void
    private let titleLabel = NSTextField(labelWithString: "Drop a URL to open it")
    private let detailLabel = NSTextField(labelWithString: "Drag a link, .webloc file, or plain-text URL here.")
    private let iconView = NSImageView()
    private var isDragTargeted = false {
        didSet { updateAppearance() }
    }

    init(onURL: @escaping (URL) -> Void) {
        self.onURL = onURL
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        registerForDraggedTypes([.URL, .fileURL, .string])
        buildLayout()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTargeted = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        guard let url = PasteboardURLReader.url(from: sender.draggingPasteboard) else {
            return false
        }

        onURL(url)
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let hasURL = PasteboardURLReader.url(from: sender.draggingPasteboard) != nil
        isDragTargeted = hasURL
        return hasURL ? .copy : []
    }

    private func buildLayout() {
        iconView.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func updateAppearance() {
        let backgroundColor = isDragTargeted ? NSColor.controlAccentColor.withAlphaComponent(0.14) : .controlBackgroundColor
        let borderColor = isDragTargeted ? NSColor.controlAccentColor : .separatorColor

        layer?.backgroundColor = resolvedCGColor(for: backgroundColor)
        layer?.borderColor = resolvedCGColor(for: borderColor)
    }

    private func resolvedCGColor(for color: NSColor) -> CGColor {
        var cgColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.clear.cgColor
        }
        return cgColor
    }
}

final class StartupWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(openURL: @escaping (URL) -> Void) {
        let contentView = NSView()
        let dropView = StartupDropView(onURL: openURL)
        dropView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dropView)

        NSLayoutConstraint.activate([
            dropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            dropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            dropView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            dropView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 440, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = AppConfig.displayName
        window.contentView = contentView
        window.minSize = NSSize(width: 360, height: 190)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class BrowserWindowController: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let initialURL: URL

    init(url: URL) {
        self.initialURL = url

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.allowsMagnification = true

        let contentView = MouseHoverTrackingView()
        let dragStrip = WindowDragStripView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        contentView.addSubview(dragStrip)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            dragStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 88),
            dragStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 28)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = AppConfig.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 480, height: 320)
        window.contentView = contentView

        super.init(window: window)

        webView.navigationDelegate = self
        window.delegate = self
        contentView.onMouseHoverChanged = { [weak self] isMouseOverWindow in
            self?.setBrowserChromeVisible(isMouseOverWindow)
        }
        setBrowserChromeVisible(false)
        load(initialURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
        window?.representedURL = url
        window?.title = url.host ?? AppConfig.displayName
    }

    func updateBrowserChromeForCurrentMouseLocation() {
        guard let window else { return }
        setBrowserChromeVisible(window.frame.contains(NSEvent.mouseLocation))
    }

    private func setBrowserChromeVisible(_ visible: Bool) {
        setWindowControlsVisible(visible)
        setScrollbarsVisible(visible)
    }

    private func setWindowControlsVisible(_ visible: Bool) {
        guard let window else { return }
        window.standardWindowButton(.closeButton)?.isHidden = !visible
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !visible
        window.standardWindowButton(.zoomButton)?.isHidden = !visible
    }

    private func setScrollbarsVisible(_ visible: Bool) {
        for scrollView in webView.descendantScrollViews() {
            scrollView.verticalScroller?.isHidden = !visible
            scrollView.horizontalScroller?.isHidden = !visible
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window?.title = webView.title ?? initialURL.host ?? AppConfig.displayName
        updateBrowserChromeForCurrentMouseLocation()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           URLNormalizer.url(from: url) != nil {
            AppDelegate.shared?.openWindow(for: url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}

private extension NSView {
    func descendantScrollViews() -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []

        if let scrollView = self as? NSScrollView {
            scrollViews.append(scrollView)
        }

        for subview in subviews {
            scrollViews.append(contentsOf: subview.descendantScrollViews())
        }

        return scrollViews
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.windowDidClose(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var windows: [BrowserWindowController] = []
    private var startupWindow: StartupWindowController?
    private var pendingURLs: [URL] = []

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
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

    func openWindow(for url: URL) {
        closeStartupWindow()
        let controller = BrowserWindowController(url: url)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.updateBrowserChromeForCurrentMouseLocation()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
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
            openStartupWindow()
        }
    }

    private func openStartupWindow() {
        if let startupWindow {
            startupWindow.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = StartupWindowController { [weak self] url in
            self?.openWindow(for: url)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.startupWindow === controller else { return }
            self.startupWindow = nil
        }
        startupWindow = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeStartupWindow() {
        startupWindow?.close()
        startupWindow = nil
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
        guard let url = PasteboardURLReader.url(from: pasteboard) else {
            error.pointee = "No URL was found on the pasteboard." as NSString
            return
        }

        openWindow(for: url)
    }

    @objc private func newWindow(_ sender: Any?) {
        openStartupDestination()
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

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
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
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        return mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
