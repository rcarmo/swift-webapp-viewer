import AppKit
import Foundation

final class StartupDropView: NSView {
    private let onURL: (URL) -> Void
    private let titleLabel = NSTextField(labelWithString: "Drop or paste a URL to open it")
    private let detailLabel = NSTextField(labelWithString: "Drag a link, .webloc file, plain-text URL, or paste a URL here.")
    private let iconView = NSImageView()
    private var isDragTargeted = false {
        didSet { updateAppearance() }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

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

    // BUG FIX: Don't eagerly parse pasteboard data in draggingEntered/Updated.
    // Cross-process drags can fail when data is read too early (lazy provision).
    // Just check if the pasteboard advertises relevant types here; validate the
    // actual URL later in prepareForDragOperation.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let dominated = hasRelevantDragTypes(sender.draggingPasteboard)
        isDragTargeted = dominated
        return dominated ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted ? .copy : []
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

    // BUG FIX: The original used bounds.contains(point) but the point parameter
    // is in the superview's coordinate system while bounds is in local coords.
    // When the view's frame origin is not (0,0) (it's inset by 24pt), points in
    // the top/left margin were incorrectly hit-tested as inside the view.
    // Using frame.contains(point) is correct since both use superview coords.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PasteboardURLReader.url(from: sender.draggingPasteboard) != nil
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }

        paste(nil)
        return true
    }

    private func hasRelevantDragTypes(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.URL, .fileURL, .string]) != nil
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
    private let dropView: StartupDropView

    init(openURL: @escaping (URL) -> Void) {
        let contentView = NSView()
        let dropView = StartupDropView(onURL: openURL)
        self.dropView = dropView
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
        window.isMovableByWindowBackground = true

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(dropView)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
