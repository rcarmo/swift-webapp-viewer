import AppKit
import Foundation
import UniformTypeIdentifiers

enum URLNormalizer {
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

enum PasteboardURLReader {
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
