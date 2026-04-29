import AppKit
import Foundation

struct WebAppInstallPlan {
    let sourceURL: URL
    let name: String
    let bundleIdentifier: String
    let destinationURL: URL
    let icon: NSImage?
}

struct WebAppInstallMetadata {
    let title: String?
    let iconChoices: [WebAppIconChoice]
}

struct WebAppIconChoice {
    let title: String
    let image: NSImage?
    let sourceURL: URL?
}

struct WebAppPageSnapshot {
    let title: String?
    let baseURL: URL
    let links: [WebAppPageLink]
}

struct WebAppPageLink {
    let rel: String
    let href: String
    let sizes: String?
}

enum WebAppInstaller {
    static func metadata(for url: URL, livePageSnapshot: WebAppPageSnapshot? = nil) async -> WebAppInstallMetadata {
        await WebAppIconResolver.metadata(for: url, livePageSnapshot: livePageSnapshot)
    }

    static func makePlan(for url: URL, name requestedName: String, icon: WebAppIconChoice?) -> WebAppInstallPlan {
        let name = sanitizedAppName(requestedName)
        let bundleIdentifier = bundleIdentifier(for: url, name: name)
        let destinationURL = applicationsDirectory()
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathExtension("app")

        return WebAppInstallPlan(
            sourceURL: url,
            name: name,
            bundleIdentifier: bundleIdentifier,
            destinationURL: destinationURL,
            icon: icon?.image
        )
    }

    static func install(_ plan: WebAppInstallPlan, replacingExisting: Bool) throws {
        let fileManager = FileManager.default
        let sourceBundleURL = Bundle.main.bundleURL
        let destinationURL = plan.destinationURL

        try fileManager.createDirectory(
            at: applicationsDirectory(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard replacingExisting else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceBundleURL, to: destinationURL)
        try removeStandaloneOnlyBundleContent(from: destinationURL)
        try writeInfoPlist(for: plan, in: destinationURL)
        try writeIcon(for: plan, in: destinationURL)
        try resignApp(at: destinationURL)
    }

    static func launch(_ appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    static func applicationsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    private static func removeStandaloneOnlyBundleContent(from appURL: URL) throws {
        let fileManager = FileManager.default
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let pluginURL = contentsURL.appendingPathComponent("PlugIns", isDirectory: true)

        if fileManager.fileExists(atPath: pluginURL.path) {
            try fileManager.removeItem(at: pluginURL)
        }
    }

    private static func writeInfoPlist(for plan: WebAppInstallPlan, in appURL: URL) throws {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.xml

        guard var info = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: &format
        ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        info["CFBundleIdentifier"] = plan.bundleIdentifier
        info["CFBundleName"] = plan.name
        info["CFBundleDisplayName"] = plan.name
        info["DefaultWebAppURL"] = plan.sourceURL.absoluteString
        info["CFBundleIconFile"] = "AppIcon"
        info.removeValue(forKey: "CFBundleDocumentTypes")
        info.removeValue(forKey: "CFBundleURLTypes")
        info.removeValue(forKey: "NSServices")

        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try updatedData.write(to: infoURL)
    }

    private static func writeIcon(for plan: WebAppInstallPlan, in appURL: URL) throws {
        let iconURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("AppIcon.icns")

        if let icon = plan.icon {
            try ICNSWriter.write(image: icon, to: iconURL)
            return
        }

        if let bundledIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            try? FileManager.default.removeItem(at: iconURL)
            try FileManager.default.copyItem(at: bundledIconURL, to: iconURL)
        }
    }

    private static func resignApp(at appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            appURL.path
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    private static func sanitizedAppName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: forbidden)
        let cleaned = components
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.nilIfBlank ?? "Web App"
    }

    private static func bundleIdentifier(for url: URL, name: String) -> String {
        let baseIdentifier = "com.example.WebAppViewer.webapp"
        let hostSlug = identifierComponent(url.host ?? name)
        let identity = "\(name)|\(url.absoluteString)"
        return "\(baseIdentifier).\(hostSlug).\(fnv1aHash(identity))"
    }

    private static func identifierComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.nilIfBlank ?? "site"
    }

    private static func fnv1aHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

private enum WebAppIconResolver {
    static func metadata(for url: URL, livePageSnapshot: WebAppPageSnapshot?) async -> WebAppInstallMetadata {
        var title = livePageSnapshot?.title?.nilIfBlank
        var candidates: [IconCandidate] = []
        var manifestCandidateURLs: [URL] = []
        var baseURL = livePageSnapshot?.baseURL ?? url

        if let livePageSnapshot {
            baseURL = livePageSnapshot.baseURL
            candidates.append(contentsOf: iconCandidates(in: livePageSnapshot.links, baseURL: livePageSnapshot.baseURL))
            manifestCandidateURLs.append(contentsOf: manifestURLs(in: livePageSnapshot.links, baseURL: livePageSnapshot.baseURL))
        }

        if let page = try? await fetchPage(at: url) {
            baseURL = page.baseURL
            title = title ?? pageTitle(in: page.html)
            candidates.append(contentsOf: iconCandidates(in: page.html, baseURL: page.baseURL))
            manifestCandidateURLs.append(contentsOf: Self.manifestURLs(in: page.html, baseURL: page.baseURL))
        }

        for manifestURL in manifestCandidateURLs {
            if let manifestCandidates = try? await iconCandidates(fromManifestAt: manifestURL) {
                candidates.append(contentsOf: manifestCandidates)
            }
        }

        if let faviconURL = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL {
            candidates.append(IconCandidate(url: faviconURL, title: "favicon.ico", score: 1))
        }

        let icons = await iconChoices(from: candidates)
        return WebAppInstallMetadata(title: title, iconChoices: icons)
    }

    private static func fetchPage(at url: URL) async throws -> (html: String, baseURL: URL) {
        let (data, response) = try await URLSession.shared.data(from: url)
        let responseURL = response.url ?? url
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        return (html, responseURL)
    }

    private static func pageTitle(in html: String) -> String? {
        guard let match = firstMatch(
            pattern: "<title[^>]*>(.*?)</title>",
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        return html[match]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private static func manifestURLs(in html: String, baseURL: URL) -> [URL] {
        linkTags(in: html).compactMap { tag in
            let attributes = attributes(in: tag)
            guard attributes["rel"]?.lowercased().contains("manifest") == true,
                  let href = attributes["href"] else {
                return nil
            }

            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
    }

    private static func manifestURLs(in links: [WebAppPageLink], baseURL: URL) -> [URL] {
        links.compactMap { link in
            guard link.rel.lowercased().contains("manifest") else { return nil }
            return URL(string: link.href, relativeTo: baseURL)?.absoluteURL
        }
    }

    private static func iconCandidates(in html: String, baseURL: URL) -> [IconCandidate] {
        linkTags(in: html).compactMap { tag in
            let attributes = attributes(in: tag)
            guard let rel = attributes["rel"]?.lowercased(),
                  rel.contains("icon"),
                  let href = attributes["href"],
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }

            let sizes = attributes["sizes"]
            return IconCandidate(
                url: url,
                title: iconTitle(rel: rel, sizes: sizes),
                score: score(forSizes: sizes, rel: rel)
            )
        }
    }

    private static func iconCandidates(in links: [WebAppPageLink], baseURL: URL) -> [IconCandidate] {
        links.compactMap { link in
            let rel = link.rel.lowercased()
            guard rel.contains("icon"),
                  let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }

            return IconCandidate(
                url: url,
                title: iconTitle(rel: rel, sizes: link.sizes),
                score: score(forSizes: link.sizes, rel: rel)
            )
        }
    }

    private static func iconCandidates(fromManifestAt url: URL) async throws -> [IconCandidate] {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = json["icons"] as? [[String: Any]] else {
            return []
        }

        return icons.compactMap { icon in
            guard let source = icon["src"] as? String,
                  let iconURL = URL(string: source, relativeTo: url)?.absoluteURL else {
                return nil
            }

            let sizes = icon["sizes"] as? String
            return IconCandidate(
                url: iconURL,
                title: iconTitle(rel: "manifest", sizes: sizes),
                score: score(forSizes: sizes, rel: "manifest")
            )
        }
    }

    private static func iconChoices(from candidates: [IconCandidate]) async -> [WebAppIconChoice] {
        let orderedCandidates = orderedUniqueCandidates(from: candidates)
        var resolvedChoices: [ResolvedIconChoice] = []

        for candidate in orderedCandidates.prefix(24) {
            guard let image = try? await fetchImage(at: candidate.candidate.url) else { continue }
            let choice = WebAppIconChoice(
                title: "\(candidate.candidate.title) \(imagePixelSizeDescription(image))",
                image: image,
                sourceURL: candidate.candidate.url
            )
            resolvedChoices.append(
                ResolvedIconChoice(
                    rankedCandidate: candidate,
                    choice: choice,
                    pixelArea: imagePixelArea(image)
                )
            )
        }

        return resolvedChoices
            .sorted(by: resolvedIconShouldPrecede(_:_:))
            .prefix(8)
            .map(\.choice)
    }

    private static func orderedUniqueCandidates(from candidates: [IconCandidate]) -> [RankedIconCandidate] {
        var uniqueCandidates: [URL: RankedIconCandidate] = [:]

        for (order, candidate) in candidates.enumerated() {
            let rankedCandidate = RankedIconCandidate(candidate: candidate, order: order)
            if let existingCandidate = uniqueCandidates[candidate.url],
               !rankedIconShouldPrecede(rankedCandidate, existingCandidate) {
                continue
            }

            uniqueCandidates[candidate.url] = rankedCandidate
        }

        return uniqueCandidates.values.sorted(by: rankedIconShouldPrecede(_:_:))
    }

    private static func rankedIconShouldPrecede(
        _ lhs: RankedIconCandidate,
        _ rhs: RankedIconCandidate
    ) -> Bool {
        if lhs.candidate.score != rhs.candidate.score {
            return lhs.candidate.score > rhs.candidate.score
        }

        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }

        return lhs.candidate.url.absoluteString < rhs.candidate.url.absoluteString
    }

    private static func resolvedIconShouldPrecede(
        _ lhs: ResolvedIconChoice,
        _ rhs: ResolvedIconChoice
    ) -> Bool {
        if lhs.rankedCandidate.candidate.score != rhs.rankedCandidate.candidate.score {
            return lhs.rankedCandidate.candidate.score > rhs.rankedCandidate.candidate.score
        }

        if lhs.pixelArea != rhs.pixelArea {
            return lhs.pixelArea > rhs.pixelArea
        }

        return rankedIconShouldPrecede(lhs.rankedCandidate, rhs.rankedCandidate)
    }

    private static func fetchImage(at url: URL) async throws -> NSImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = NSImage(data: data), image.isValid else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return image
    }

    private static func linkTags(in html: String) -> [String] {
        matches(pattern: "<link\\s+[^>]*>", in: html, options: [.caseInsensitive])
            .map { String(html[$0]) }
    }

    private static func attributes(in tag: String) -> [String: String] {
        var values: [String: String] = [:]
        let ranges = matches(
            pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            in: tag,
            options: []
        )

        for range in ranges {
            let attribute = String(tag[range])
            guard let equalsIndex = attribute.firstIndex(of: "=") else { continue }

            let key = attribute[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = attribute[attribute.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return values
    }

    private static func score(forSizes sizes: String?, rel: String) -> Int {
        let relBonus: Int
        if rel.contains("manifest") {
            relBonus = 2_000_000
        } else if rel.contains("apple-touch-icon") {
            relBonus = 1_000_000
        } else {
            relBonus = 0
        }
        guard let sizes else { return relBonus + 1 }

        let sizeScores = sizes
            .split(separator: " ")
            .compactMap { size -> Int? in
                let parts = size.lowercased().split(separator: "x")
                guard parts.count == 2,
                      let width = Int(parts[0]),
                      let height = Int(parts[1]) else {
                    return nil
                }

                return width * height
            }

        return relBonus + (sizeScores.max() ?? 1)
    }

    private static func iconTitle(rel: String, sizes: String?) -> String {
        if rel.contains("manifest") {
            return "Manifest icon"
        }

        if rel.contains("apple-touch-icon") {
            return "Apple touch icon"
        }

        return "Favicon"
    }

    private static func imagePixelSizeDescription(_ image: NSImage) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        return "(\(cgImage.width)x\(cgImage.height))"
    }

    private static func imagePixelArea(_ image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }

        return cgImage.width * cgImage.height
    }

    private static func matches(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options
    ) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value)
        }
    }

    private static func firstMatch(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options
    ) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }

        return Range(match.range(at: 1), in: value)
    }
}

private struct IconCandidate {
    let url: URL
    let title: String
    let score: Int
}

private struct RankedIconCandidate {
    let candidate: IconCandidate
    let order: Int
}

private struct ResolvedIconChoice {
    let rankedCandidate: RankedIconCandidate
    let choice: WebAppIconChoice
    let pixelArea: Int
}

private enum ICNSWriter {
    private static let renditions: [(type: String, size: Int)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("icp6", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024)
    ]

    static func write(image: NSImage, to destination: URL) throws {
        var chunks = Data()

        for rendition in renditions {
            let pngData = try pngData(from: image, size: rendition.size)
            appendFourCC(rendition.type, to: &chunks)
            appendUInt32BE(UInt32(pngData.count + 8), to: &chunks)
            chunks.append(pngData)
        }

        var icns = Data()
        appendFourCC("icns", to: &icns)
        appendUInt32BE(UInt32(chunks.count + 8), to: &icns)
        icns.append(chunks)
        try icns.write(to: destination)
    }

    private static func pngData(from image: NSImage, size: Int) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let canvas = CGRect(x: 0, y: 0, width: size, height: size)
        let drawRect = aspectFitRect(
            imageSize: CGSize(width: source.width, height: source.height),
            in: canvas
        )

        context.clear(canvas)
        context.interpolationQuality = .high
        context.draw(source, in: drawRect)

        guard let icon = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let bitmap = NSBitmapImageRep(cgImage: icon)
        bitmap.size = CGSize(width: size, height: size)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return data
    }

    private static func aspectFitRect(imageSize: CGSize, in canvas: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return canvas }

        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: canvas.midX - width / 2,
            y: canvas.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func appendFourCC(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
