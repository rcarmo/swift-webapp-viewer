import Foundation

enum AppConfig {
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

enum BrowserIdentity {
    static var safariUserAgent: String {
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = [
            operatingSystemVersion.majorVersion,
            operatingSystemVersion.minorVersion,
            operatingSystemVersion.patchVersion
        ]
            .map(String.init)
            .joined(separator: "_")

        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osVersion)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    private static var safariVersion: String {
        for path in ["/Applications/Safari.app", "/System/Applications/Safari.app"] {
            guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                  let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            return value
        }

        return fallbackSafariVersion
    }

    private static var fallbackSafariVersion: String {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVersion >= 26 {
            return "\(majorVersion).0"
        }

        if majorVersion >= 15 {
            return "18.0"
        }

        return "17.0"
    }
}
