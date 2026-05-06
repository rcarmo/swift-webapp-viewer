import AppKit
import Foundation
import JavaScriptCore

struct UserScriptConfiguration: Codable, Equatable, Identifiable {
    var id: UUID
    var isEnabled: Bool
    var name: String
    var urlPattern: String
    var source: String

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        name: String,
        urlPattern: String,
        source: String
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.urlPattern = urlPattern
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.name = try container.decode(String.self, forKey: .name)
        self.urlPattern = try container.decode(String.self, forKey: .urlPattern)
        self.source = try container.decode(String.self, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case name
        case urlPattern
        case source
    }

    var displayName: String {
        name.nilIfBlank ?? "Untitled Script"
    }

    var trimmedSource: String? {
        source.nilIfBlank
    }

    func matches(_ url: URL) -> Bool {
        let pattern = urlPattern.nilIfBlank ?? ".*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let value = url.absoluteString
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range) != nil
    }

    func hasValidPattern() -> Bool {
        (try? NSRegularExpression(pattern: urlPattern.nilIfBlank ?? ".*")) != nil
    }
}

struct JavaScriptSyntaxIssue {
    let message: String
    let line: Int?
    let column: Int?

    var displayMessage: String {
        if let line, let column {
            return "JavaScript syntax error on line \(line), column \(column): \(message)"
        }

        if let line {
            return "JavaScript syntax error on line \(line): \(message)"
        }

        return "JavaScript syntax error: \(message)"
    }
}

enum JavaScriptSyntaxValidator {
    static func firstIssue(in source: String) -> JavaScriptSyntaxIssue? {
        guard source.nilIfBlank != nil,
              let literal = javaScriptStringLiteral(for: source),
              let context = JSContext() else {
            return nil
        }

        var issue: JavaScriptSyntaxIssue?
        context.exceptionHandler = { _, exception in
            guard let exception else { return }

            let rawLine = exception.forProperty("line")?.toInt32() ?? 0
            let rawColumn = exception.forProperty("column")?.toInt32() ?? 0
            let line = rawLine > 2 ? Int(rawLine - 2) : nil
            let column = rawColumn > 0 ? Int(rawColumn) : nil
            let message = exception.toString()
                .replacingOccurrences(of: #"^SyntaxError:\s*"#, with: "", options: .regularExpression)

            issue = JavaScriptSyntaxIssue(message: message, line: line, column: column)
        }

        context.evaluateScript("new Function(\(literal));")
        return issue
    }

    private static func javaScriptStringLiteral(for source: String) -> String? {
        guard let data = try? JSONEncoder().encode(source) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

final class UserScriptStore {
    static let shared = UserScriptStore()

    private let defaultsKey = "UserScripts"
    private let defaults: UserDefaults
    private(set) var scripts: [UserScriptConfiguration]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scripts = Self.loadScripts(from: defaults, key: defaultsKey)
    }

    @discardableResult
    func addScript() -> UserScriptConfiguration {
        let script = UserScriptConfiguration(
            name: "New Script",
            urlPattern: ".*",
            source: """
            // JavaScript runs after matching pages finish loading.
            console.log("Web App Viewer user script loaded", location.href);
            """
        )
        scripts.append(script)
        save()
        return script
    }

    func update(_ script: UserScriptConfiguration) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        save()
    }

    func removeScript(id: UUID) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func scripts(matching url: URL) -> [UserScriptConfiguration] {
        scripts.filter { $0.isEnabled && $0.matches(url) && $0.trimmedSource != nil }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(scripts) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private static func loadScripts(from defaults: UserDefaults, key: String) -> [UserScriptConfiguration] {
        guard defaults.object(forKey: key) != nil else {
            return [hackerNewsDarkModeExample]
        }

        guard let data = defaults.data(forKey: key),
              let scripts = try? JSONDecoder().decode([UserScriptConfiguration].self, from: data) else {
            return [hackerNewsDarkModeExample]
        }

        return refreshBundledExamples(in: scripts)
    }

    private static func refreshBundledExamples(in scripts: [UserScriptConfiguration]) -> [UserScriptConfiguration] {
        var refreshedScripts = scripts
        guard let index = refreshedScripts.firstIndex(where: isBundledHackerNewsExample) else {
            refreshedScripts.append(hackerNewsDarkModeExample)
            return refreshedScripts
        }

        let current = refreshedScripts[index]
        refreshedScripts[index] = UserScriptConfiguration(
            id: current.id,
            isEnabled: current.isEnabled,
            name: hackerNewsDarkModeExample.name,
            urlPattern: hackerNewsDarkModeExample.urlPattern,
            source: hackerNewsDarkModeExample.source
        )
        return refreshedScripts
    }

    private static func isBundledHackerNewsExample(_ script: UserScriptConfiguration) -> Bool {
        let name = script.displayName.lowercased()
        guard name.hasPrefix("example: hacker news") else {
            return false
        }

        return script.urlPattern == #"https://news\.ycombinator\.com/.*"#
    }

    private static let hackerNewsDarkModeExample = UserScriptConfiguration(
        isEnabled: false,
        name: "Example: Hacker News Dark Mode + Avatars",
        urlPattern: #"https://news\.ycombinator\.com/.*"#,
        source: #"""
        // Example user script for Web App Viewer.
        // Attribution:
        // - Dark theme adapted from Hacker News - Dark Theme by Jesse Tolj
        //   (MIT License, https://greasyfork.org/en/scripts/510432-hacker-news-dark-theme)
        //   with additional inspiration from susam/userscript Dark HN
        //   (MIT License, https://github.com/susam/userscript).
        // - Generated user avatar idea inspired by "HN Avatars in 357 bytes"
        //   by tomxor and the IntersectionObserver variant by onion2k:
        //   https://news.ycombinator.com/item?id=30668137

        const FORCE_DARK_MODE = false;
        const FOLLOW_SYSTEM_APPEARANCE = true;
        const ENABLE_AVATARS = true;

        const styleID = "webappviewer-hn-polish";
        document.getElementById(styleID)?.remove();

        const style = document.createElement("style");
        style.id = styleID;
        style.textContent = `
          :root[data-webappviewer-hn-theme="dark"] {
            color-scheme: dark;
            --hn-page-background: #0a0a0a;
            --hn-background: #171717;
            --hn-background-alt: #1f1f1f;
            --hn-accent: #ff6600;
            --hn-accent-text: #fff7ed;
            --hn-text: #d4d4d4;
            --hn-text-strong: #f5f5f5;
            --hn-text-muted: #a3a3a3;
            --hn-text-faint: #737373;
            --hn-title: #f5f5f5;
            --hn-title-visited: #cbd5e1;
            --hn-header-link: #fff7ed;
            --hn-border: #404040;
            --hn-link: #f97316;
            --hn-link-hover: #fb923c;
            --hn-link-visited: #d97706;
            --hn-input-background: #171717;
            --hn-input-border: #525252;
            --hn-warning-background: #7f1d1d;
          }

          :root[data-webappviewer-hn-theme="dark"] body,
          :root[data-webappviewer-hn-theme="dark"] center {
            background: var(--hn-page-background) !important;
            color: var(--hn-text) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] #hnmain {
            background-color: var(--hn-background) !important;
            border-collapse: collapse;
            box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06);
          }

          :root[data-webappviewer-hn-theme="dark"] .topcolor,
          :root[data-webappviewer-hn-theme="dark"] td[bgcolor="#ff6600"] {
            background-color: var(--hn-accent) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] td[bgcolor="#ffffaa"] {
            background-color: var(--hn-warning-background) !important;
            color: var(--hn-text-strong) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .pagetop {
            height: 28px !important;
            color: var(--hn-header-link) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .pagetop a,
          :root[data-webappviewer-hn-theme="dark"] .hnname a {
            background: transparent !important;
            color: var(--hn-header-link) !important;
            font-weight: 600 !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .title,
          :root[data-webappviewer-hn-theme="dark"] .title a,
          :root[data-webappviewer-hn-theme="dark"] .titleline,
          :root[data-webappviewer-hn-theme="dark"] .titleline a {
            color: var(--hn-title) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .subtext,
          :root[data-webappviewer-hn-theme="dark"] .subtext a,
          :root[data-webappviewer-hn-theme="dark"] .yclinks,
          :root[data-webappviewer-hn-theme="dark"] .yclinks a,
          :root[data-webappviewer-hn-theme="dark"] .sitestr,
          :root[data-webappviewer-hn-theme="dark"] .score,
          :root[data-webappviewer-hn-theme="dark"] .age,
          :root[data-webappviewer-hn-theme="dark"] .hnuser {
            color: var(--hn-text-muted) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] a:link {
            color: var(--hn-link) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] a:visited {
            color: var(--hn-link-visited) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] a:hover {
            color: var(--hn-link-hover) !important;
            text-decoration: underline !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .pagetop,
          :root[data-webappviewer-hn-theme="dark"] .pagetop font,
          :root[data-webappviewer-hn-theme="dark"] .pagetop b,
          :root[data-webappviewer-hn-theme="dark"] .pagetop a,
          :root[data-webappviewer-hn-theme="dark"] .pagetop a:link,
          :root[data-webappviewer-hn-theme="dark"] .pagetop a:visited,
          :root[data-webappviewer-hn-theme="dark"] .pagetop a:hover,
          :root[data-webappviewer-hn-theme="dark"] .hnname,
          :root[data-webappviewer-hn-theme="dark"] .hnname a,
          :root[data-webappviewer-hn-theme="dark"] .hnname a:link,
          :root[data-webappviewer-hn-theme="dark"] .hnname a:visited,
          :root[data-webappviewer-hn-theme="dark"] .hnname a:hover {
            color: var(--hn-header-link) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .title,
          :root[data-webappviewer-hn-theme="dark"] .title a,
          :root[data-webappviewer-hn-theme="dark"] .title a:link,
          :root[data-webappviewer-hn-theme="dark"] .titleline,
          :root[data-webappviewer-hn-theme="dark"] .titleline a,
          :root[data-webappviewer-hn-theme="dark"] .titleline a:link,
          :root[data-webappviewer-hn-theme="dark"] .morelink,
          :root[data-webappviewer-hn-theme="dark"] .morelink:link {
            color: var(--hn-title) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .title a:visited,
          :root[data-webappviewer-hn-theme="dark"] .titleline a:visited,
          :root[data-webappviewer-hn-theme="dark"] .morelink:visited {
            color: var(--hn-title-visited) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .subtext,
          :root[data-webappviewer-hn-theme="dark"] .subtext a,
          :root[data-webappviewer-hn-theme="dark"] .subtext a:link,
          :root[data-webappviewer-hn-theme="dark"] .subtext a:visited,
          :root[data-webappviewer-hn-theme="dark"] .yclinks,
          :root[data-webappviewer-hn-theme="dark"] .yclinks a,
          :root[data-webappviewer-hn-theme="dark"] .yclinks a:link,
          :root[data-webappviewer-hn-theme="dark"] .yclinks a:visited,
          :root[data-webappviewer-hn-theme="dark"] .sitestr,
          :root[data-webappviewer-hn-theme="dark"] .score,
          :root[data-webappviewer-hn-theme="dark"] .age,
          :root[data-webappviewer-hn-theme="dark"] .hnuser,
          :root[data-webappviewer-hn-theme="dark"] .hnuser:link,
          :root[data-webappviewer-hn-theme="dark"] .hnuser:visited {
            color: var(--hn-text-muted) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .comment,
          :root[data-webappviewer-hn-theme="dark"] .commtext,
          :root[data-webappviewer-hn-theme="dark"] .commtext p,
          :root[data-webappviewer-hn-theme="dark"] .comment-tree,
          :root[data-webappviewer-hn-theme="dark"] .toptext {
            color: var(--hn-text) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .comhead,
          :root[data-webappviewer-hn-theme="dark"] .comhead a,
          :root[data-webappviewer-hn-theme="dark"] .comhead a:link,
          :root[data-webappviewer-hn-theme="dark"] .comhead a:visited,
          :root[data-webappviewer-hn-theme="dark"] font[color="#828282"] {
            color: var(--hn-text-muted) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .commtext code,
          :root[data-webappviewer-hn-theme="dark"] .commtext pre {
            background: var(--hn-background-alt) !important;
            border-radius: 4px !important;
            color: var(--hn-text-strong) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] textarea,
          :root[data-webappviewer-hn-theme="dark"] input[type="text"],
          :root[data-webappviewer-hn-theme="dark"] input[type="url"],
          :root[data-webappviewer-hn-theme="dark"] input[type="password"] {
            background: var(--hn-input-background) !important;
            border: 1px solid var(--hn-input-border) !important;
            color: var(--hn-text-strong) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] input[type="submit"],
          :root[data-webappviewer-hn-theme="dark"] button {
            background: var(--hn-background-alt) !important;
            border: 1px solid var(--hn-border) !important;
            color: var(--hn-text-strong) !important;
          }

          :root[data-webappviewer-hn-theme="dark"] .votelinks {
            opacity: 0.58;
          }

          :root[data-webappviewer-hn-theme="dark"] .votearrow {
            filter: invert(1) brightness(1.5);
          }

          :root[data-webappviewer-hn-theme="dark"] tr.spacer {
            background: var(--hn-background) !important;
          }

          .webappviewer-hn-user {
            align-items: center;
            display: inline-flex;
            gap: 4px;
            vertical-align: -3px;
          }

          .webappviewer-hn-avatar {
            border-radius: 3px;
            box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.28);
            height: 11px;
            image-rendering: pixelated;
            margin-right: 1px;
            width: 11px;
          }
        `;

        document.documentElement.appendChild(style);

        const darkModeQuery = window.matchMedia("(prefers-color-scheme: dark)");

        function wantsDarkMode() {
          return FORCE_DARK_MODE || (FOLLOW_SYSTEM_APPEARANCE && darkModeQuery.matches);
        }

        function applyAppearance() {
          if (wantsDarkMode()) {
            document.documentElement.setAttribute("data-webappviewer-hn-theme", "dark");
          } else {
            document.documentElement.removeAttribute("data-webappviewer-hn-theme");
          }
        }

        applyAppearance();

        if (FOLLOW_SYSTEM_APPEARANCE) {
          darkModeQuery.addEventListener?.("change", applyAppearance);
        }

        if (ENABLE_AVATARS) {
          const observedUsers = new WeakSet();
          const renderedUsers = new WeakSet();

          function seedForName(name) {
            let seed = 1;
            for (const character of name) {
              seed = (seed + character.charCodeAt(0)) | 0;
              seed ^= seed << 13;
              seed ^= seed >>> 17;
              seed ^= seed << 5;
            }
            return seed || 1;
          }

          function nextRandom(seed) {
            seed ^= seed << 13;
            seed ^= seed >>> 17;
            seed ^= seed << 5;
            return seed | 0;
          }

          function drawAvatar(link) {
            if (renderedUsers.has(link)) {
              return;
            }

            renderedUsers.add(link);

            const username = link.textContent?.trim();
            if (!username) {
              return;
            }

            const canvas = document.createElement("canvas");
            const scale = 2;
            const columns = 7;
            const rows = 7;
            canvas.className = "webappviewer-hn-avatar";
            canvas.width = columns * scale;
            canvas.height = rows * scale;
            canvas.title = `${username} avatar`;

            const context = canvas.getContext("2d");
            if (!context) {
              return;
            }

            let seed = seedForName(username);
            const hue = Math.abs(seed) % 360;
            context.fillStyle = `hsl(${hue} 68% 58%)`;

            for (let y = 0; y < rows; y += 1) {
              for (let x = 0; x < 4; x += 1) {
                seed = nextRandom(seed);
                const density = 5.6 - y * 0.52 - Math.abs(3 - x) * 0.72;
                if ((seed >>> 29) > density) {
                  continue;
                }

                context.fillRect((3 + x) * scale, y * scale, scale, scale);
                context.fillRect((3 - x) * scale, y * scale, scale, scale);
              }
            }

            if (link.parentElement?.classList.contains("webappviewer-hn-user") != true) {
              const wrapper = document.createElement("span");
              wrapper.className = "webappviewer-hn-user";
              link.parentNode?.insertBefore(wrapper, link);
              wrapper.append(canvas, link);
            } else {
              link.parentElement.prepend(canvas);
            }
          }

          const avatarObserver = new IntersectionObserver((entries) => {
            for (const entry of entries) {
              if (entry.isIntersecting && entry.target instanceof HTMLElement) {
                drawAvatar(entry.target);
                avatarObserver.unobserve(entry.target);
              }
            }
          }, { rootMargin: "120px 0px" });

          function observeUsers(root = document) {
            if (root instanceof Element && root.matches("a.hnuser") && !observedUsers.has(root)) {
              observedUsers.add(root);
              avatarObserver.observe(root);
            }

            root.querySelectorAll("a.hnuser").forEach((link) => {
              if (observedUsers.has(link)) {
                return;
              }

              observedUsers.add(link);
              avatarObserver.observe(link);
            });
          }

          const mutationObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
              for (const node of mutation.addedNodes) {
                if (node instanceof Element) {
                  observeUsers(node);
                }
              }
            }
          });

          function startAvatars() {
            observeUsers();

            if (document.body) {
              mutationObserver.observe(document.body, { childList: true, subtree: true });
            }
          }

          if (document.body) {
            startAvatars();
          } else {
            document.addEventListener("DOMContentLoaded", startAvatars, { once: true });
          }
        }
        """#
    )
}

final class JavaScriptCodeTextView: NSTextView {
    private let editorFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var isHighlighting = false
    private var syntaxIssue: JavaScriptSyntaxIssue?

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        self.init(
            frame: NSRect(x: 0, y: 0, width: 560, height: 360),
            textContainer: textContainer
        )
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCode(_ value: String) {
        string = value
        highlightSyntax()
    }

    func setSyntaxIssue(_ issue: JavaScriptSyntaxIssue?) {
        syntaxIssue = issue
        highlightSyntax()
    }

    override func didChangeText() {
        super.didChangeText()
        highlightSyntax()
    }

    private func configure() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = true
        font = editorFont
        textColor = .textColor
        insertionPointColor = .textColor
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 10, height: 10)
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
    }

    private func highlightSyntax() {
        guard !isHighlighting,
              let storage = textStorage else {
            return
        }

        isHighlighting = true
        let selectedRanges = self.selectedRanges
        let fullRange = NSRange(location: 0, length: (string as NSString).length)

        storage.beginEditing()
        storage.setAttributes([
            .font: editorFont,
            .foregroundColor: NSColor.textColor
        ], range: fullRange)

        apply(pattern: #"\b(?:await|async|break|case|catch|class|const|continue|default|delete|do|else|export|finally|for|from|function|if|import|in|instanceof|let|new|null|return|switch|this|throw|try|typeof|undefined|var|void|while|window|document|true|false)\b"#, color: .systemBlue, storage: storage, range: fullRange)
        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, color: .systemPurple, storage: storage, range: fullRange)
        apply(pattern: #"//[^\n]*|/\*[\s\S]*?\*/"#, color: .secondaryLabelColor, storage: storage, range: fullRange)
        apply(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, color: .systemGreen, storage: storage, range: fullRange)
        applySyntaxIssueHighlight(storage: storage)

        storage.endEditing()
        self.selectedRanges = selectedRanges
        isHighlighting = false
    }

    private func applySyntaxIssueHighlight(storage: NSTextStorage) {
        guard let line = syntaxIssue?.line,
              let lineRange = rangeForLine(line) else {
            return
        }

        storage.addAttributes([
            .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.16),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemOrange
        ], range: lineRange)
    }

    private func rangeForLine(_ targetLine: Int) -> NSRange? {
        guard targetLine > 0 else { return nil }

        let value = string as NSString
        var currentLine = 1
        var lineStart = 0

        while currentLine < targetLine {
            let searchRange = NSRange(location: lineStart, length: value.length - lineStart)
            let newlineRange = value.range(of: "\n", options: [], range: searchRange)
            if newlineRange.location == NSNotFound {
                return nil
            }

            lineStart = newlineRange.location + newlineRange.length
            currentLine += 1
        }

        let searchRange = NSRange(location: lineStart, length: value.length - lineStart)
        let newlineRange = value.range(of: "\n", options: [], range: searchRange)
        let lineEnd = newlineRange.location == NSNotFound ? value.length : newlineRange.location
        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }

    private func apply(
        pattern: String,
        color: NSColor,
        storage: NSTextStorage,
        range: NSRange
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: color, range: matchRange)
        }
    }
}

final class UserScriptTableCellView: NSTableCellView {
    var onEnabledChanged: ((Bool) -> Void)?

    private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with script: UserScriptConfiguration) {
        enabledButton.state = script.isEnabled ? .on : .off
        titleField.stringValue = script.displayName
        detailField.stringValue = script.urlPattern.nilIfBlank ?? "All URLs"
        iconView.contentTintColor = script.hasValidPattern() ? .controlAccentColor : .systemOrange
        titleField.textColor = script.isEnabled ? .labelColor : .secondaryLabelColor
        detailField.textColor = script.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        iconView.alphaValue = script.isEnabled ? 1.0 : 0.45
    }

    private func configure() {
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged(_:))
        enabledButton.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(enabledButton)
        addSubview(iconView)
        addSubview(titleField)
        addSubview(detailField)

        NSLayoutConstraint.activate([
            enabledButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            enabledButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            enabledButton.widthAnchor.constraint(equalToConstant: 18),
            enabledButton.heightAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: enabledButton.trailingAnchor, constant: 7),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1)
        ])
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        onEnabledChanged?(sender.state == .on)
    }
}

// BUG FIX: Removed all hardcoded NSColor.white.cgColor backgrounds that broke
// dark mode. The window, split view, and table view now use default system
// backgrounds which respect the user's appearance setting.
final class UserScriptPreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let store = UserScriptStore.shared
    private let tableView = NSTableView()
    private let nameField = NSTextField(frame: .zero)
    private let patternField = NSTextField(frame: .zero)
    private let codeView = JavaScriptCodeTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "-", target: nil, action: nil)
    private var codeBottomToStatusConstraint: NSLayoutConstraint?
    private var codeBottomToContainerConstraint: NSLayoutConstraint?

    private var selectedID: UUID?
    private var isUpdatingControls = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "User Scripts"
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        reloadSelectingFirstIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.scripts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("UserScriptCell")
        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? UserScriptTableCellView
            ?? UserScriptTableCellView()
        let script = store.scripts[row]
        cellView.identifier = identifier
        cellView.configure(with: script)
        cellView.onEnabledChanged = { [weak self, id = script.id] isEnabled in
            self?.setScript(id: id, isEnabled: isEnabled)
        }
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0,
              store.scripts.indices.contains(tableView.selectedRow) else {
            selectedID = nil
            updateControls(for: nil)
            return
        }

        let script = store.scripts[tableView.selectedRow]
        selectedID = script.id
        updateControls(for: script)
    }

    func controlTextDidChange(_ notification: Notification) {
        persistSelectedScript(refreshingList: true)
    }

    func textDidChange(_ notification: Notification) {
        persistSelectedScript(refreshingList: false)
    }

    private func buildContent() {
        guard let window,
              let contentView = window.contentView else {
            return
        }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let detail = buildDetailPane()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        sidebar.widthAnchor.constraint(equalToConstant: 230).isActive = true

        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func buildSidebar() -> NSView {
        let container = NSView()

        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.style = .sourceList
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.delegate = self
        tableView.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Scripts"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let controlBar = NSView()
        controlBar.wantsLayer = true
        controlBar.layer?.cornerRadius = 8
        controlBar.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
        controlBar.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "+", target: self, action: #selector(addScript(_:)))
        addButton.bezelStyle = .shadowlessSquare
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 17, weight: .regular)
        addButton.toolTip = "Add User Script"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton.target = self
        removeButton.action = #selector(removeScript(_:))
        removeButton.bezelStyle = .shadowlessSquare
        removeButton.isBordered = false
        removeButton.font = .systemFont(ofSize: 17, weight: .regular)
        removeButton.toolTip = "Remove User Script"
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        controlBar.addSubview(addButton)
        controlBar.addSubview(divider)
        controlBar.addSubview(removeButton)
        container.addSubview(scrollView)
        container.addSubview(controlBar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: controlBar.topAnchor, constant: -8),

            controlBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            controlBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            controlBar.widthAnchor.constraint(equalToConstant: 75),
            controlBar.heightAnchor.constraint(equalToConstant: 28),

            addButton.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor),
            addButton.topAnchor.constraint(equalTo: controlBar.topAnchor),
            addButton.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 37),

            divider.leadingAnchor.constraint(equalTo: addButton.trailingAnchor),
            divider.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 18),
            divider.widthAnchor.constraint(equalToConstant: 1),

            removeButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            removeButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor),
            removeButton.topAnchor.constraint(equalTo: controlBar.topAnchor),
            removeButton.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor)
        ])

        return container
    }

    private func buildDetailPane() -> NSView {
        let container = NSView()

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.alignment = .right
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "Script name"
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let patternLabel = NSTextField(labelWithString: "URL Regex:")
        patternLabel.alignment = .right
        patternLabel.translatesAutoresizingMaskIntoConstraints = false

        patternField.placeholderString = #"https://example\.com/.*"#
        patternField.delegate = self
        patternField.translatesAutoresizingMaskIntoConstraints = false

        codeView.delegate = self
        let codeScrollView = NSScrollView()
        codeScrollView.borderType = .bezelBorder
        codeScrollView.hasVerticalScroller = true
        codeScrollView.hasHorizontalScroller = true
        codeScrollView.autohidesScrollers = true
        codeScrollView.drawsBackground = true
        codeScrollView.backgroundColor = .textBackgroundColor
        codeView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 560, height: 340)
        )
        codeView.autoresizingMask = [.width]
        codeScrollView.documentView = codeView
        codeScrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [nameLabel, nameField, patternLabel, patternField, codeScrollView, statusLabel] as [NSView] {
            container.addSubview(view)
        }

        codeBottomToStatusConstraint = codeScrollView.bottomAnchor.constraint(
            equalTo: statusLabel.topAnchor,
            constant: -8
        )
        codeBottomToContainerConstraint = codeScrollView.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: -14
        )
        codeBottomToContainerConstraint?.isActive = true

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            nameLabel.widthAnchor.constraint(equalToConstant: 78),

            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            patternLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            patternLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 18),
            patternLabel.widthAnchor.constraint(equalTo: nameLabel.widthAnchor),

            patternField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            patternField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            patternField.centerYAnchor.constraint(equalTo: patternLabel.centerYAnchor),

            codeScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            codeScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            codeScrollView.topAnchor.constraint(equalTo: patternField.bottomAnchor, constant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: codeScrollView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: codeScrollView.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])

        return container
    }

    private func reloadSelectingFirstIfNeeded() {
        tableView.reloadData()

        let selectedIndex: Int
        if let selectedID,
           let index = store.scripts.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = store.scripts.isEmpty ? -1 : 0
        }

        if selectedIndex >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            updateControls(for: nil)
        }
    }

    private func updateControls(for script: UserScriptConfiguration?) {
        isUpdatingControls = true
        let isEnabled = script != nil
        nameField.isEnabled = isEnabled
        patternField.isEnabled = isEnabled
        codeView.isEditable = isEnabled
        removeButton.isEnabled = isEnabled

        nameField.stringValue = script?.name ?? ""
        patternField.stringValue = script?.urlPattern ?? ""
        codeView.setCode(script?.source ?? "")
        updateStatus(for: script)
        isUpdatingControls = false
    }

    private func persistSelectedScript(refreshingList shouldRefreshList: Bool) {
        guard !isUpdatingControls,
              let selectedID,
              let current = store.scripts.first(where: { $0.id == selectedID }) else {
            return
        }

        let updated = UserScriptConfiguration(
            id: current.id,
            isEnabled: current.isEnabled,
            name: nameField.stringValue,
            urlPattern: patternField.stringValue,
            source: codeView.string
        )
        store.update(updated)
        if shouldRefreshList {
            tableView.reloadData()
        }
        updateStatus(for: updated)
    }

    private func setScript(id: UUID, isEnabled: Bool) {
        guard let script = store.scripts.first(where: { $0.id == id }) else { return }
        let updated = UserScriptConfiguration(
            id: script.id,
            isEnabled: isEnabled,
            name: script.name,
            urlPattern: script.urlPattern,
            source: script.source
        )
        store.update(updated)
        if selectedID == id {
            updateStatus(for: updated)
        }
        tableView.reloadData()
    }

    private func updateStatus(for script: UserScriptConfiguration?) {
        guard let script else {
            codeView.setSyntaxIssue(nil)
            setStatus("")
            return
        }

        if !script.isEnabled {
            codeView.setSyntaxIssue(nil)
            setStatus("")
        } else if !script.hasValidPattern() {
            codeView.setSyntaxIssue(nil)
            setStatus("Invalid URL regular expression. This script will not run.", color: .systemOrange)
        } else if let issue = JavaScriptSyntaxValidator.firstIssue(in: script.source) {
            codeView.setSyntaxIssue(issue)
            setStatus(issue.displayMessage, color: .systemOrange)
        } else {
            codeView.setSyntaxIssue(nil)
            setStatus("")
        }
    }

    private func setStatus(_ message: String, color: NSColor = .secondaryLabelColor) {
        let hasMessage = !message.isEmpty
        statusLabel.stringValue = message
        statusLabel.textColor = color
        statusLabel.isHidden = !hasMessage
        codeBottomToStatusConstraint?.isActive = hasMessage
        codeBottomToContainerConstraint?.isActive = !hasMessage
    }

    @objc private func addScript(_ sender: Any?) {
        let script = store.addScript()
        selectedID = script.id
        reloadSelectingFirstIfNeeded()
        window?.makeFirstResponder(nameField)
    }

    @objc private func removeScript(_ sender: Any?) {
        guard let selectedID else { return }
        store.removeScript(id: selectedID)
        self.selectedID = nil
        reloadSelectingFirstIfNeeded()
    }
}
