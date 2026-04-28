import AppKit
import Foundation
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "Opening...")
        label.alignment = .center
        label.textColor = .secondaryLabelColor

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        self.view = view
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        openFirstSharedURL()
    }

    private func openFirstSharedURL() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        loadURL(from: providers) { [weak self] url in
            DispatchQueue.main.async {
                self?.openHostApp(with: url)
            }
        }
    }

    private func loadURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                completion(Self.url(from: item))
            }
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                completion(Self.url(from: item))
            }
            return
        }

        completion(nil)
    }

    private func openHostApp(with url: URL?) {
        defer {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }

        guard let url,
              let appURL = Self.hostAppURL(for: url) else {
            return
        }

        extensionContext?.open(appURL, completionHandler: nil)
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return normalizedURL(from: url.absoluteString)
        }

        if let string = item as? String {
            return normalizedURL(from: string)
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return normalizedURL(from: string)
        }

        return nil
    }

    private static func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), isWebURL(url) {
            return url
        }

        if !trimmed.contains("://"),
           let url = URL(string: "https://\(trimmed)"),
           isWebURL(url) {
            return url
        }

        return nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func hostAppURL(for url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "webappviewer"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString)
        ]
        return components.url
    }
}
