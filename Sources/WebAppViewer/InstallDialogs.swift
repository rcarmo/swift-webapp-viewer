import AppKit
import Foundation
import UniformTypeIdentifiers

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
