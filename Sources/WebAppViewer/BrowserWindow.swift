import AppKit
import Foundation
import UserNotifications
import WebKit

final class WindowDragStripView: NSView {
    private var mouseDownEvent: NSEvent?
    private let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent else { return }

        let deltaX = event.locationInWindow.x - mouseDownEvent.locationInWindow.x
        let deltaY = event.locationInWindow.y - mouseDownEvent.locationInWindow.y
        guard hypot(deltaX, deltaY) >= dragThreshold else {
            return
        }

        self.mouseDownEvent = nil
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
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

enum WebNotificationBridge {
    static let messageHandlerName = "webAppViewerNotification"

    static let script = """
    (() => {
      if (window.__webAppViewerNotificationBridgeInstalled) return;
      const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.webAppViewerNotification;
      if (!native) return;

      window.__webAppViewerNotificationBridgeInstalled = true;
      let permission = "default";
      let nextPermissionRequest = 1;
      const pendingPermissionRequests = new Map();

      function post(message) {
        try {
          native.postMessage(message);
        } catch (_) {}
      }

      function completePermissionRequest(id, value) {
        permission = value;
        const complete = pendingPermissionRequests.get(String(id));
        if (!complete) return;
        pendingPermissionRequests.delete(String(id));
        complete(value);
      }

      function WebAppViewerNotification(title, options) {
        options = options || {};
        this.title = String(title || "");
        this.body = options.body ? String(options.body) : "";
        this.tag = options.tag ? String(options.tag) : "";
        this.icon = options.icon ? String(options.icon) : "";
        this.close = function() {};

        if (permission === "granted") {
          post({
            type: "show",
            title: this.title,
            body: this.body,
            tag: this.tag,
            icon: this.icon,
            url: window.location.href
          });
        }
      }

      WebAppViewerNotification.requestPermission = function(callback) {
        const id = String(nextPermissionRequest++);
        post({ type: "requestPermission", id });

        return new Promise((resolve) => {
          pendingPermissionRequests.set(id, (value) => {
            if (typeof callback === "function") callback(value);
            resolve(value);
          });
        });
      };

      Object.defineProperty(WebAppViewerNotification, "permission", {
        get() { return permission; }
      });

      window.__webAppViewerNotificationPermissionResult = completePermissionRequest;
      window.Notification = WebAppViewerNotification;
    })();
    """
}

// BUG FIX: Breaks the retain cycle between BrowserWindowController and
// WKUserContentController. Previously, add(self, name:) created a strong
// reference from the content controller back to the window controller,
// preventing deinit from ever running. This weak proxy avoids the cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class BrowserWindowController: NSWindowController, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    private let webView: WKWebView
    private let initialURL: URL
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]

    init(url: URL) {
        self.initialURL = url

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        Self.enableDeveloperExtras(on: configuration.preferences)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebNotificationBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.customUserAgent = BrowserIdentity.safariUserAgent
        self.webView.isInspectable = true
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
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebNotificationBridge.messageHandlerName
        )
        UNUserNotificationCenter.current().delegate = self
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

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebNotificationBridge.messageHandlerName
        )
    }

    func load(_ url: URL) {
        installUserScripts(for: url)
        webView.load(URLRequest(url: url))
        window?.representedURL = url
        window?.title = url.host ?? AppConfig.displayName
    }

    func reload() {
        if let url = currentURL {
            installUserScripts(for: url)
        }
        webView.reload()
    }

    func zoomIn() {
        setPageZoom(webView.pageZoom * 1.1)
    }

    func zoomOut() {
        setPageZoom(webView.pageZoom / 1.1)
    }

    func resetZoom() {
        setPageZoom(1.0)
    }

    func showWebInspector() {
        Self.enableDeveloperExtras(on: webView.configuration.preferences)
        webView.isInspectable = true
        window?.makeFirstResponder(webView)

        if performInspectorSelector(on: webView, names: [
            "showWebInspector:",
            "_showWebInspector:",
            "showInspector:",
            "_showInspector:"
        ]) {
            return
        }

        let inspectorSelector = NSSelectorFromString("_inspector")
        if webView.responds(to: inspectorSelector),
           let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject,
           performInspectorSelector(on: inspector, names: [
            "show",
            "show:",
            "showConsole",
            "showConsole:"
           ]) {
            return
        }

        webView.evaluateJavaScript("debugger;")
    }

    var currentURL: URL? {
        webView.url ?? window?.representedURL ?? initialURL
    }

    var appHomeURL: URL {
        initialURL
    }

    var suggestedAppName: String? {
        webView.title?.nilIfBlank
            ?? window?.title.nilIfBlank
            ?? currentURL?.host
    }

    @MainActor func livePageSnapshot(for installURL: URL) async -> WebAppPageSnapshot? {
        guard let currentURL,
              currentURL.isSameInstallMetadataDocument(as: installURL) else {
            return nil
        }

        let script = """
        JSON.stringify({
          title: document.title || "",
          baseURL: document.baseURI || window.location.href,
          links: Array.from(document.querySelectorAll("link[rel]")).map((link) => ({
            rel: link.rel || link.getAttribute("rel") || "",
            href: link.href || link.getAttribute("href") || "",
            sizes: link.sizes ? link.sizes.value : (link.getAttribute("sizes") || "")
          }))
        })
        """

        guard let json = await evaluateJavaScriptString(script),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseURLValue = object["baseURL"] as? String,
              let baseURL = URL(string: baseURLValue) else {
            return nil
        }

        let links = (object["links"] as? [[String: Any]] ?? []).compactMap { link -> WebAppPageLink? in
            guard let href = link["href"] as? String,
                  !href.isEmpty else {
                return nil
            }

            return WebAppPageLink(
                rel: link["rel"] as? String ?? "",
                href: href,
                sizes: link["sizes"] as? String
            )
        }

        return WebAppPageSnapshot(
            title: (object["title"] as? String)?.nilIfBlank,
            baseURL: baseURL,
            links: links
        )
    }

    @MainActor private func evaluateJavaScriptString(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
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

    private func setPageZoom(_ value: CGFloat) {
        webView.pageZoom = min(max(value, 0.5), 3.0)
    }

    private static func enableDeveloperExtras(on preferences: WKPreferences) {
        let selector = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: selector) else { return }
        preferences.setValue(true, forKey: "_developerExtrasEnabled")
    }

    private func performInspectorSelector(on target: NSObject, names: [String]) -> Bool {
        for name in names {
            let selector = NSSelectorFromString(name)
            guard target.responds(to: selector) else { continue }

            if name.hasSuffix(":") {
                target.perform(selector, with: nil)
            } else {
                target.perform(selector)
            }
            return true
        }

        return false
    }

    private func installUserScripts(for url: URL) {
        let userContentController = webView.configuration.userContentController
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(
            WKUserScript(
                source: WebNotificationBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        for script in UserScriptStore.shared.scripts(matching: url) {
            guard let source = script.trimmedSource else { continue }
            userContentController.addUserScript(
                WKUserScript(
                    source: wrappedUserScript(source, displayName: script.displayName),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
    }

    private func wrappedUserScript(_ source: String, displayName: String) -> String {
        """
            (() => {
              try {
            \(source)
              } catch (error) {
                console.error(\(javaScriptStringLiteral("Web App Viewer user script failed: \(displayName)")), error);
              }
            })();
            //# sourceURL=webappviewer-userscript-\(sanitizedSourceURLName(displayName)).js
            """
    }

    private func sanitizedSourceURLName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.nilIfBlank ?? "script"
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
        guard let url = navigationAction.request.url,
              URLNormalizer.url(from: url) != nil else {
            decisionHandler(.allow)
            return
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if shouldOpenInSafari(url, navigationAction: navigationAction) {
            openInSafari(url)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            AppDelegate.shared?.openWindow(for: url)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            installUserScripts(for: url)
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        completionHandler(downloadDestination(for: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebNotificationBridge.messageHandlerName,
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        switch type {
        case "requestPermission":
            guard let requestID = payload["id"] as? String else { return }
            requestNotificationPermission(requestID: requestID)
        case "show":
            presentNotification(from: payload)
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func shouldOpenInSafari(
        _ url: URL,
        navigationAction: WKNavigationAction
    ) -> Bool {
        let opensNewWindow = navigationAction.targetFrame == nil
        let userClickedLink = navigationAction.navigationType == .linkActivated
        return (opensNewWindow || userClickedLink) && !url.isSameWebOrigin(as: initialURL)
    }

    private func openInSafari(_ url: URL) {
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration)
    }

    private func track(_ download: WKDownload) {
        activeDownloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    private func downloadDestination(for suggestedFilename: String) -> URL {
        let fileManager = FileManager.default
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let filename = sanitizedDownloadFilename(suggestedFilename)
        let baseURL = downloadsDirectory.appendingPathComponent(filename, isDirectory: false)

        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let basename = baseURL.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(basename) \(index)"
            } else {
                candidateName = "\(basename) \(index).\(fileExtension)"
            }

            let candidateURL = downloadsDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }

    private func sanitizedDownloadFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.nilIfBlank ?? "download"
    }

    private func requestNotificationPermission(requestID: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.resolveNotificationPermission(
                    requestID: requestID,
                    permission: granted ? "granted" : "denied"
                )
            }
        }
    }

    private func resolveNotificationPermission(requestID: String, permission: String) {
        let script = """
        window.__webAppViewerNotificationPermissionResult && window.__webAppViewerNotificationPermissionResult(\(javaScriptStringLiteral(requestID)), \(javaScriptStringLiteral(permission)));
        """
        webView.evaluateJavaScript(script)
    }

    private func presentNotification(from payload: [String: Any]) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.addNotification(from: payload)
            case .notDetermined:
                notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self?.addNotification(from: payload)
                }
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    private func addNotification(from payload: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = (payload["title"] as? String)?.nilIfBlank ?? AppConfig.displayName
        content.body = (payload["body"] as? String)?.nilIfBlank ?? ""
        content.sound = .default

        if let tag = (payload["tag"] as? String)?.nilIfBlank {
            content.threadIdentifier = tag
        }

        if let url = (payload["url"] as? String)?.nilIfBlank {
            content.userInfo = ["url": url]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return String(arrayLiteral.dropFirst().dropLast())
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.windowDidClose(self)
    }
}

extension NSView {
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

extension URL {
    func isSameWebOrigin(as other: URL) -> Bool {
        guard let lhs = URLComponents(url: self, resolvingAgainstBaseURL: true),
              let rhs = URLComponents(url: other, resolvingAgainstBaseURL: true) else {
            return false
        }

        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.normalizedPort == rhs.normalizedPort
    }

    func isSameInstallMetadataDocument(as other: URL) -> Bool {
        guard let lhs = URLComponents(url: self, resolvingAgainstBaseURL: true),
              let rhs = URLComponents(url: other, resolvingAgainstBaseURL: true) else {
            return absoluteString == other.absoluteString
        }

        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && normalizedInstallPath(lhs.path) == normalizedInstallPath(rhs.path)
            && lhs.query == rhs.query
    }

    private func normalizedInstallPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }
}

extension URLComponents {
    var normalizedPort: Int? {
        if let port { return port }

        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
