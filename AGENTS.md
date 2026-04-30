# Repository Instructions

This is a small native macOS utility built directly with `swiftc` through the
project Makefile.

## Build And Verify

- Use `make debug` for local compile/sign/verify checks during development.
- Use `make release` before shipping; it creates `dist/WebAppViewer.zip`.
- The app is ad-hoc signed by default. Do not describe release zips as
  Developer ID signed or notarized unless signing and notarization have been
  added deliberately.

## Stable Releases

- Stable minor and patch releases are tagged from a local commit, not invented
  by CI.
- Use `make bump-patch` or `make bump-minor` to update `Info.plist` and
  `ShareExtensionInfo.plist`; this also makes the intended release tag
  `v<CFBundleShortVersionString>`.
- Review the version change, run `make release`, commit the version and release
  support changes, then run `make tag-release` on the clean committed tree.
- Push the commit and tag together, for example:

  ```sh
  git push origin main v1.2.3
  ```

- Pushing a `v*` tag triggers GitHub Actions to build the archive, create a
  GitHub Release, attach the zip and checksum under Releases, and publish
  generated release notes.
