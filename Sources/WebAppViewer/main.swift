import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications
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
    private let titleLabel = NSTextField(labelWithString: "Drop or paste a URL to open it")
    private let detailLabel = NSTextField(labelWithString: "Drag a link, .webloc file, plain-text URL, or paste a URL here.")
    private let iconView = NSImageView()
    private var isDragTargeted = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
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

    @objc func paste(_ sender: Any?) {
        guard let url = PasteboardURLReader.url(from: .general) else {
            NSSound.beep()
            return
        }

        onURL(url)
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

final class WebAppInstallURLDialog: NSObject {
    private let suggestedURL: URL?
    private let panel: NSPanel
    private let urlField = NSTextField(frame: .zero)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(suggestedURL: URL?) {
        self.suggestedURL = suggestedURL
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildPanel()
    }

    func run() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK else { return nil }
        return URLNormalizer.url(from: urlField.stringValue)
    }

    private func buildPanel() {
        panel.title = "Choose URL"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        guard let contentView = panel.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Choose URL")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.frame = NSRect(x: 28, y: 164, width: 320, height: 24)

        let detailLabel = NSTextField(labelWithString: "Enter the web address to inspect for a page title and installable icons.")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 28, y: 136, width: 564, height: 36)
        detailLabel.maximumNumberOfLines = 2

        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.alignment = .right
        urlLabel.frame = NSRect(x: 28, y: 86, width: 72, height: 20)

        urlField.frame = NSRect(x: 112, y: 82, width: 480, height: 24)
        urlField.stringValue = suggestedURL?.absoluteString ?? ""

        cancelButton.frame = NSRect(x: 416, y: 24, width: 88, height: 28)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        continueButton.frame = NSRect(x: 512, y: 24, width: 84, height: 28)
        continueButton.target = self
        continueButton.action = #selector(continueInstall(_:))
        continueButton.keyEquivalent = "\r"

        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(urlLabel)
        contentView.addSubview(urlField)
        contentView.addSubview(cancelButton)
        contentView.addSubview(continueButton)
    }

    @objc private func continueInstall(_ sender: Any?) {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel(_ sender: Any?) {
        NSApp.stopModal(withCode: .cancel)
    }
}

final class WebAppInstallDialog: NSObject {
    private let url: URL
    private let initialName: String
    private let pageIconCount: Int
    private var iconChoices: [WebAppIconChoice]
    private var droppedIconIndex: Int?

    private let panel: NSPanel
    private let nameField = NSTextField(frame: .zero)
    private let iconPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = IconDropImageView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Looking for page icons...")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(url: URL, suggestedName: String?, metadata: WebAppInstallMetadata) {
        self.url = url
        self.initialName = metadata.title?.nilIfBlank ?? suggestedName ?? url.host ?? "Web App"
        self.pageIconCount = metadata.iconChoices.count
        self.iconChoices = metadata.iconChoices + [
            WebAppIconChoice(title: "Default Web App Viewer icon", image: nil, sourceURL: nil)
        ]
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildPanel()
    }

    func run() -> WebAppInstallPlan? {
        refreshIconMenu(selecting: 0)

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        guard response == .OK,
              let name = nameField.stringValue.nilIfBlank else {
            return nil
        }

        return WebAppInstaller.makePlan(
            for: url,
            name: name,
            icon: selectedIcon
        )
    }

    private var selectedIcon: WebAppIconChoice? {
        guard iconChoices.indices.contains(iconPopup.indexOfSelectedItem) else { return nil }
        return iconChoices[iconPopup.indexOfSelectedItem]
    }

    private func buildPanel() {
        panel.title = "Customize Web App"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        guard let contentView = panel.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Customize Web App")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.frame = NSRect(x: 28, y: 284, width: 320, height: 24)

        let detailLabel = NSTextField(labelWithString: "Rename it and choose an icon before saving it to \(WebAppInstaller.applicationsDirectory().path).")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 28, y: 250, width: 564, height: 36)
        detailLabel.maximumNumberOfLines = 2

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.alignment = .right
        nameLabel.frame = NSRect(x: 28, y: 206, width: 72, height: 20)

        nameField.frame = NSRect(x: 112, y: 202, width: 480, height: 24)
        nameField.stringValue = initialName

        let iconLabel = NSTextField(labelWithString: "Icon:")
        iconLabel.alignment = .right
        iconLabel.frame = NSRect(x: 28, y: 162, width: 72, height: 20)

        iconPopup.frame = NSRect(x: 112, y: 156, width: 480, height: 28)
        iconPopup.target = self
        iconPopup.action = #selector(iconSelectionChanged(_:))

        preview.frame = NSRect(x: 112, y: 60, width: 80, height: 80)
        preview.image = NSApp.applicationIconImage
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.toolTip = "Drop an image here to use it as the app icon."
        preview.onImageDrop = { [weak self] image, sourceURL in
            self?.useDroppedIcon(image, sourceURL: sourceURL)
        }
        preview.onImageURLDrop = { [weak self] url in
            self?.loadDroppedIcon(from: url)
        }

        statusLabel.stringValue = "Found \(pageIconCount) page icon\(pageIconCount == 1 ? "" : "s")."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.frame = NSRect(x: 212, y: 92, width: 380, height: 20)

        cancelButton.frame = NSRect(x: 416, y: 24, width: 88, height: 28)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.frame = NSRect(x: 512, y: 24, width: 84, height: 28)
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"

        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(nameField)
        contentView.addSubview(iconLabel)
        contentView.addSubview(iconPopup)
        contentView.addSubview(preview)
        contentView.addSubview(statusLabel)
        contentView.addSubview(cancelButton)
        contentView.addSubview(saveButton)
    }

    private func refreshIconMenu(selecting index: Int) {
        iconPopup.removeAllItems()
        for choice in iconChoices {
            iconPopup.addItem(withTitle: choice.title)
            iconPopup.lastItem?.image = menuImage(from: choice.image)
        }

        let selectedIndex = iconChoices.indices.contains(index) ? index : 0
        iconPopup.selectItem(at: selectedIndex)
        preview.image = iconChoices[selectedIndex].image ?? NSApp.applicationIconImage
    }

    @objc private func iconSelectionChanged(_ sender: NSPopUpButton) {
        preview.image = selectedIcon?.image ?? NSApp.applicationIconImage
    }

    private func useDroppedIcon(_ image: NSImage, sourceURL: URL?) {
        let choice = WebAppIconChoice(
            title: "Dropped image \(imagePixelSizeDescription(image))",
            image: image,
            sourceURL: sourceURL
        )

        if let droppedIconIndex,
           iconChoices.indices.contains(droppedIconIndex) {
            iconChoices[droppedIconIndex] = choice
            refreshIconMenu(selecting: droppedIconIndex)
        } else {
            iconChoices.insert(choice, at: 0)
            droppedIconIndex = 0
            refreshIconMenu(selecting: 0)
        }

        statusLabel.stringValue = "Using dropped image."
    }

    private func loadDroppedIcon(from url: URL) {
        if url.isFileURL,
           let image = NSImage(contentsOf: url) {
            useDroppedIcon(image, sourceURL: url)
            return
        }

        Task { @MainActor [weak self] in
            guard let image = await Self.image(at: url) else { return }
            self?.useDroppedIcon(image, sourceURL: url)
        }
    }

    @objc private func save(_ sender: Any?) {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel(_ sender: Any?) {
        NSApp.stopModal(withCode: .cancel)
    }

    private func menuImage(from image: NSImage?) -> NSImage? {
        guard let source = image ?? NSApp.applicationIconImage else {
            return nil
        }
        let copy = source.copy() as? NSImage
        copy?.size = NSSize(width: 18, height: 18)
        return copy
    }

    private func imagePixelSizeDescription(_ image: NSImage) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        return "(\(cgImage.width)x\(cgImage.height))"
    }

    private static func image(at url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data),
              image.isValid else {
            return nil
        }

        return image
    }
}

final class IconDropImageView: NSImageView {
    var onImageDrop: ((NSImage, URL?) -> Void)?
    var onImageURLDrop: ((URL) -> Void)?

    private var isDropTargeted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDropTarget()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        isDropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        let pasteboard = sender.draggingPasteboard

        if let image = NSImage(pasteboard: pasteboard) {
            onImageDrop?(image, imageURL(from: pasteboard))
            return true
        }

        if let url = imageURL(from: pasteboard) {
            onImageURLDrop?(url)
            return true
        }

        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isDropTargeted else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        path.stroke()
    }

    private func configureDropTarget() {
        wantsLayer = true
        layer?.cornerRadius = 8
        registerForDraggedTypes([.fileURL, .URL, .tiff, .png, .string])
    }

    private func accepts(_ pasteboard: NSPasteboard) -> Bool {
        NSImage(pasteboard: pasteboard) != nil || imageURL(from: pasteboard) != nil
    }

    private func imageURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first {
            return url
        }

        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .string] {
            guard let value = pasteboard.string(forType: type),
                  let url = imageURL(from: value) else {
                continue
            }

            if url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }

        return nil
    }

    private func fileURL(from value: String) -> URL? {
        let expandedPath = (value as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else { return nil }
        return URL(fileURLWithPath: expandedPath)
    }

    private func imageURL(from value: String) -> URL? {
        if let url = URL(string: value),
           url.scheme != nil {
            return url
        }

        return fileURL(from: value)
    }
}

private enum WebNotificationBridge {
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

final class BrowserWindowController: NSWindowController, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    private let webView: WKWebView
    private let initialURL: URL
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]

    init(url: URL) {
        self.initialURL = url

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebNotificationBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

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
        configuration.userContentController.add(self, name: WebNotificationBridge.messageHandlerName)
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
        webView.load(URLRequest(url: url))
        window?.representedURL = url
        window?.title = url.host ?? AppConfig.displayName
    }

    func reload() {
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

private extension URL {
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

private extension URLComponents {
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

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.windowDidClose(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var windows: [BrowserWindowController] = []
    private var blankWindows: [StartupWindowController] = []
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
        terminateIfNoWindowsRemain()
    }

    private func activeBrowserWindow() -> BrowserWindowController? {
        windows.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isMainWindow == true }
            ?? windows.last
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
        var controller: StartupWindowController?
        controller = StartupWindowController { [weak self, weak controller] url in
            if let controller {
                self?.closeBlankWindow(controller)
            }
            self?.openWindow(for: url)
        }
        controller?.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.blankWindowDidClose(controller)
        }
        guard let controller else { return }

        blankWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeBlankWindow(_ controller: StartupWindowController) {
        controller.close()
        blankWindowDidClose(controller)
    }

    private func blankWindowDidClose(_ controller: StartupWindowController) {
        blankWindows.removeAll { $0 === controller }
        terminateIfNoWindowsRemain()
    }

    private func terminateIfNoWindowsRemain() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.windows.isEmpty,
                  self.blankWindows.isEmpty else {
                return
            }

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
        guard let url = PasteboardURLReader.url(from: pasteboard) else {
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

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
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
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
