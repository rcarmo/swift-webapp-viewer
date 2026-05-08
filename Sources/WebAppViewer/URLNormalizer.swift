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

        if let detectedURL = firstDetectedURL(in: trimmed) {
            return detectedURL
        }

        if let htmlURL = firstHTMLLinkURL(in: trimmed) {
            return htmlURL
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

    private static func firstDetectedURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url,
              isOpenableWebURL(url) else {
            return nil
        }

        return url
    }

    private static func firstHTMLLinkURL(in text: String) -> URL? {
        let pattern = #"(?i)href\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let hrefRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return url(from: String(text[hrefRange]))
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
    private static let chromiumSourceURLType = NSPasteboard.PasteboardType("org.chromium.source-url")
    private static let chromiumInternalSourceRfhTokenType = NSPasteboard.PasteboardType("org.chromium.internal.source-rfh-token")

    private static let legacyURLTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("Apple URL pasteboard type"),
        NSPasteboard.PasteboardType("WebURLPboardType"),
        NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
        NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x75726C20")
    ]

    private static let canonicalURLTypes: [NSPasteboard.PasteboardType] = [
        chromiumSourceURLType,
        .URL,
        .fileURL,
        .string,
        .html,
        .rtf,
        .tabularText,
        NSPasteboard.PasteboardType("public.url"),
        NSPasteboard.PasteboardType("public.url-name"),
        NSPasteboard.PasteboardType("public.utf8-plain-text"),
        NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")
    ]

    static var dragRegistrationTypes: [NSPasteboard.PasteboardType] {
        canonicalURLTypes + legacyURLTypes
    }

    private static var traceEnabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["WEBAPPVIEWER_TRACE_URL_INTAKE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let environmentValue,
           ["1", "true", "yes", "on"].contains(environmentValue) {
            return true
        }

        if let environmentValue,
           ["0", "false", "no", "off"].contains(environmentValue) {
            return false
        }

        if let userDefaultValue = UserDefaults.standard.object(forKey: "WebAppViewerTraceURLIntake") as? Bool {
            return userDefaultValue
        }

        return true
    }

    private static func trace(_ message: String) {
        guard traceEnabled else { return }
        let formatted = "[URLIntake] \(message)"
        NSLog("%@", formatted)
        appendTraceLine(formatted)
    }

    private static func contextLabel(_ context: String?) -> String {
        if let context, !context.isEmpty {
            return "[\(context)] "
        }
        return ""
    }

    private static func pasteboardTypesSummary(_ pasteboard: NSPasteboard) -> String {
        let rootTypes = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        let itemTypes = (pasteboard.pasteboardItems ?? [])
            .enumerated()
            .map { index, item in
                let itemTypeNames = item.types.map(\.rawValue).joined(separator: ",")
                return "#\(index):[\(itemTypeNames)]"
            }
            .joined(separator: " ")

        return "root=[\(rootTypes)] items=\(itemTypes)"
    }

    private static func sanitizedURLTextCandidates(from value: String) -> [String] {
        let cleaned = value
            .replacingOccurrences(of: "\u{0000}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var candidates = [cleaned]

        let separators = CharacterSet.whitespacesAndNewlines
        let tokens = cleaned
            .components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[]{}.,;"))
            }
            .filter { !$0.isEmpty }
        candidates.append(contentsOf: tokens)

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func url(fromPossiblyCompositeString value: String) -> URL? {
        for candidate in sanitizedURLTextCandidates(from: value) {
            if let url = URLNormalizer.url(from: candidate) {
                return url
            }
        }
        return nil
    }

    private static func appendTraceLine(_ line: String) {
        let logURL = URL(fileURLWithPath: "/tmp/WebAppViewer-urlintake.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = entry.data(using: .utf8) else {
            return
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: data)
            return
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logURL) else {
            return
        }
        defer { try? fileHandle.close() }
        _ = try? fileHandle.seekToEnd()
        try? fileHandle.write(contentsOf: data)
    }

    static func canContainURL(_ pasteboard: NSPasteboard) -> Bool {
        if let availableType = pasteboard.availableType(from: dragRegistrationTypes) {
            trace("canContainURL matched pasteboard type \(availableType.rawValue)")
            return true
        }

        if pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self], options: nil) {
            trace("canContainURL matched readable NSURL/NSString objects")
            return true
        }

        for item in pasteboard.pasteboardItems ?? [] {
            if let availableType = item.availableType(from: dragRegistrationTypes) {
                trace("canContainURL matched pasteboard item type \(availableType.rawValue)")
                return true
            }
        }

        trace("canContainURL no compatible types; \(pasteboardTypesSummary(pasteboard))")
        return false
    }

    static func url(from pasteboard: NSPasteboard, context: String? = nil) -> URL? {
        let contextPrefix = contextLabel(context)

        if let legacyURL = NSURL(from: pasteboard) as URL?,
           let normalized = URLNormalizer.url(from: legacyURL) {
            trace("\(contextPrefix)decoded URL via NSURL(from:) -> \(normalized.absoluteString)")
            return normalized
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.compactMap(URLNormalizer.url(from:)).first {
            trace("\(contextPrefix)decoded URL via readObjects(NSURL) -> \(url.absoluteString)")
            return url
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
           let url = strings.compactMap(URLNormalizer.url(from:)).first {
            trace("\(contextPrefix)decoded URL via readObjects(NSString) -> \(url.absoluteString)")
            return url
        }

        if let attributed = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil) as? [NSAttributedString],
           let url = attributed.compactMap(url(from:)).first {
            trace("\(contextPrefix)decoded URL via readObjects(NSAttributedString) -> \(url.absoluteString)")
            return url
        }

        if let chromiumSourceURL = pasteboard.string(forType: chromiumSourceURLType),
           let url = url(fromPossiblyCompositeString: chromiumSourceURL) {
            trace("\(contextPrefix)decoded URL via org.chromium.source-url -> \(url.absoluteString)")
            return url
        }

        let preferredTypes = dragRegistrationTypes
        for item in pasteboard.pasteboardItems ?? [] {
            let orderedTypes = preferredTypes + item.types.filter { !preferredTypes.contains($0) }
            for type in orderedTypes {
                if let url = url(from: item, type: type) {
                    trace("\(contextPrefix)decoded URL via pasteboard item type \(type.rawValue) -> \(url.absoluteString)")
                    return url
                }
            }
        }

        if let rawURL = pasteboard.string(forType: .URL),
           let url = URLNormalizer.url(from: rawURL) {
            trace("\(contextPrefix)decoded URL via .URL string -> \(url.absoluteString)")
            return url
        }

        if let string = pasteboard.string(forType: .string),
           let url = URLNormalizer.url(from: string) {
            trace("\(contextPrefix)decoded URL via .string -> \(url.absoluteString)")
            return url
        }

        for type in legacyURLTypes {
            if let url = url(from: pasteboard, type: type) {
                trace("\(contextPrefix)decoded URL via legacy type \(type.rawValue) -> \(url.absoluteString)")
                return url
            }
        }

        for type in pasteboard.types ?? [] {
            if let url = url(from: pasteboard, type: type) {
                trace("\(contextPrefix)decoded URL via root type \(type.rawValue) -> \(url.absoluteString)")
                return url
            }
        }

        trace("\(contextPrefix)failed to decode URL; \(pasteboardTypesSummary(pasteboard))")
        return nil
    }

    private static func url(from item: NSPasteboardItem, type: NSPasteboard.PasteboardType) -> URL? {
        if type == chromiumInternalSourceRfhTokenType {
            return nil
        }

        if let propertyList = item.propertyList(forType: type),
           let parsed = NSURL(
               pasteboardPropertyList: propertyList,
               ofType: type
           ) as URL?,
           let url = URLNormalizer.url(from: parsed) {
            return url
        }

        if let value = item.string(forType: type),
           let url = url(fromPossiblyCompositeString: value) {
            return url
        }

        if let propertyList = item.propertyList(forType: type),
           let url = url(fromPropertyList: propertyList) {
            return url
        }

        if let data = item.data(forType: type),
           let url = url(fromData: data) {
            return url
        }

        return nil
    }

    private static func url(fromPropertyList value: Any) -> URL? {
        switch value {
        case let url as URL:
            return URLNormalizer.url(from: url)
        case let url as NSURL:
            return URLNormalizer.url(from: url as URL)
        case let string as String:
            return url(fromPossiblyCompositeString: string)
        case let strings as [String]:
            return strings.compactMap(url(fromPossiblyCompositeString:)).first
        case let array as [Any]:
            return array.lazy.compactMap(url(fromPropertyList:)).first
        case let dictionary as [String: Any]:
            if let webArchiveURL = url(fromWebArchive: dictionary) {
                return webArchiveURL
            }
            return dictionary.values.lazy.compactMap(url(fromPropertyList:)).first
        default:
            return nil
        }
    }

    private static func url(fromData data: Data) -> URL? {
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .unicode, .ascii]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding),
               let url = URLNormalizer.url(from: value) {
                return url
            }
        }

        if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return url(fromPropertyList: propertyList)
        }

        if let attributedURL = url(fromAttributedData: data) {
            return attributedURL
        }

        return nil
    }

    private static func url(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> URL? {
        if type == chromiumInternalSourceRfhTokenType {
            return nil
        }

        if let propertyList = pasteboard.propertyList(forType: type),
           let parsed = NSURL(
               pasteboardPropertyList: propertyList,
               ofType: type
           ) as URL?,
           let url = URLNormalizer.url(from: parsed) {
            return url
        }

        if let value = pasteboard.string(forType: type),
           let url = url(fromPossiblyCompositeString: value) {
            return url
        }

        if let data = pasteboard.data(forType: type),
           let url = url(fromData: data) {
            return url
        }

        return nil
    }

    private static func url(from attributed: NSAttributedString) -> URL? {
        var found: URL?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
            guard found == nil else {
                stop.pointee = true
                return
            }

            if let url = value as? URL,
               let normalized = URLNormalizer.url(from: url) {
                found = normalized
                stop.pointee = true
                return
            }

            if let value = value as? String,
               let normalized = URLNormalizer.url(from: value) {
                found = normalized
                stop.pointee = true
            }
        }

        if let found {
            return found
        }

        return URLNormalizer.url(from: attributed.string)
    }

    private static func url(fromAttributedData data: Data) -> URL? {
        let optionsList: [[NSAttributedString.DocumentReadingOptionKey: Any]] = [
            [.documentType: NSAttributedString.DocumentType.html],
            [.documentType: NSAttributedString.DocumentType.rtf],
            [.documentType: NSAttributedString.DocumentType.rtfd]
        ]

        for options in optionsList {
            if let attributed = try? NSAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            ),
               let url = url(from: attributed) {
                return url
            }
        }

        return nil
    }

    private static func url(fromWebArchive dictionary: [String: Any]) -> URL? {
        if let mainResource = dictionary["WebMainResource"] as? [String: Any],
           let value = mainResource["WebResourceURL"] as? String,
           let url = URLNormalizer.url(from: value) {
            return url
        }

        return nil
    }
}
