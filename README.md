# Web App Viewer

![Web App Viewer icon](docs/icon-256.png)

A tiny native macOS shell for opening a specific website in WebKit windows without Safari's browser chrome.

This exists because Safari Web Apps still feel like they bring too much browser furniture along for the ride, especially in fullscreen. Web App Viewer is deliberately plain: one web page, one native window, as little visible chrome as macOS will reasonably allow.

## Behavior

- Opens `DefaultWebAppURL` from `Info.plist` on launch.
- Opens every supplied URL in a new window.
- Uses an invisible draggable strip at the top of each window, starting just to the right of the traffic lights.
- Hides the traffic-light controls whenever the window is not active.
- Accepts `.webloc`, `public.url`, and plain text URL drops on the Dock icon.
- Adds an "Open in Web App Viewer" macOS Service for selected URLs or URL-like text.
- Includes a macOS Share Extension that forwards shared URLs to a new app window.
- Registers the `webappviewer://open?url=...` URL scheme for integrations.

## Design Notes

The app is intentionally not a browser replacement. It has no address bar, tab strip, bookmark bar, toolbar, or Safari-style fullscreen frame. Pages open in separate windows, and the only hidden affordance is a narrow drag area at the top so the window can still be moved when the titlebar is visually suppressed.

More background is in [docs/background.md](docs/background.md).

## Configure The Site

Edit `DefaultWebAppURL` in `Info.plist`:

```xml
<key>DefaultWebAppURL</key>
<string>https://example.com</string>
```

## Build

```sh
make
```

The app bundle is created at:

```text
.build/WebAppViewer.app
```

## Run

```sh
make run
```

After building, macOS may need a moment to notice the Service and Share Extension entries. Logging out and back in, or opening System Settings > Keyboard > Keyboard Shortcuts > Services and Extensions > Sharing, usually refreshes them.

## Release

```sh
make release
```

Release archives are written to:

```text
dist/WebAppViewer.zip
```

## License

MIT License. Copyright (c) 2026 Rui Carmo.
