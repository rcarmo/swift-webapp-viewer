# Background

Web App Viewer was created out of frustration with Safari's Web Apps.

Safari's feature is convenient, but the resulting windows can still feel too much like Safari: visible chrome, a persistent browser identity, and fullscreen behavior that does not fully disappear into the app you are trying to use. For focused web tools, dashboards, and self-hosted apps, that extra frame can be enough to make the experience feel heavier than it needs to be.

This app takes the opposite stance:

- show the web page in a native WebKit window
- keep the titlebar visually quiet
- hide the traffic lights and scrollbars when the pointer is away
- leave only a small invisible strip for dragging the window
- accept URLs from Dock drops, Services, the Share sheet, and a custom URL scheme

It is intentionally small and hackable. To make it your own site wrapper, change `DefaultWebAppURL` in `Info.plist`, replace the icons in `docs/`, and rebuild.
