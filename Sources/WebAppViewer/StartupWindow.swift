import AppKit
import Foundation

private final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class StartupWindow: NSPanel {
    var onCommandPaste: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandV = event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"

        if isCommandV, onCommandPaste?() == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

final class StartupDropView: NSView, NSUserInterfaceValidations {
    static let acceptedDragTypes = PasteboardURLReader.dragRegistrationTypes

    private let onURL: (URL) -> Void
    private let titleLabel = NSTextField(labelWithString: "Drop or paste a URL to open it")
    private let detailLabel = NSTextField(labelWithString: "Drag a link, .webloc file, plain-text URL, or paste a URL here.")
    private let iconView = NSImageView()
    private var isDragTargeted = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init(openURL: @escaping (URL) -> Void) {
        self.onURL = openURL
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        registerForDraggedTypes(Self.acceptedDragTypes)
        buildLayout()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreFocus()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
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

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted || PasteboardURLReader.canContainURL(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        return openURL(from: sender.draggingPasteboard, beepOnFailure: false)
    }

    @objc func paste(_ sender: Any?) {
        _ = pasteFromGeneralPasteboard()
    }

    @discardableResult
    func pasteFromGeneralPasteboard() -> Bool {
        openURL(from: .general, beepOnFailure: true)
    }

    func makePreferredFirstResponder() {
        restoreFocus()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(paste(_:))
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let isEligible = pasteboardCanContainURL(sender.draggingPasteboard)
        isDragTargeted = isEligible
        return isEligible ? .copy : []
    }

    private func pasteboardCanContainURL(_ pasteboard: NSPasteboard) -> Bool {
        PasteboardURLReader.canContainURL(pasteboard)
    }

    @discardableResult
    private func openURL(from pasteboard: NSPasteboard, beepOnFailure: Bool) -> Bool {
        let context = beepOnFailure ? "startup-paste" : "startup-drop"
        guard let url = PasteboardURLReader.url(from: pasteboard, context: context) else {
            if beepOnFailure {
                NSSound.beep()
            }
            return false
        }

        DispatchQueue.main.async { [onURL] in
            onURL(url)
        }
        return true
    }

    private func restoreFocus() {
        window?.makeFirstResponder(self)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
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

        let stack = PassthroughStackView(views: [iconView, titleLabel, detailLabel])
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

    private let dropView: StartupDropView

    init(openURL: @escaping (URL) -> Void) {
        let contentView = NSView()
        let dropView = StartupDropView(openURL: openURL)
        self.dropView = dropView
        dropView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dropView)

        NSLayoutConstraint.activate([
            dropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            dropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            dropView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            dropView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])

        let window = StartupWindow(
            contentRect: NSRect(x: 160, y: 160, width: 440, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.title = AppConfig.displayName
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = contentView
        window.initialFirstResponder = dropView
        window.minSize = NSSize(width: 360, height: 190)
        window.isMovableByWindowBackground = true
        window.onCommandPaste = { [weak dropView] in
            dropView?.pasteFromGeneralPasteboard() == true
        }

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        dropView.makePreferredFirstResponder()
    }

    func pasteFromGeneralPasteboard() -> Bool {
        dropView.pasteFromGeneralPasteboard()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        dropView.makePreferredFirstResponder()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
