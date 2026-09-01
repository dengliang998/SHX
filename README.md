<div align="center">
  <img src="Assets/AppIcon/SHXIcon.svg" width="128" height="128" alt="SHX icon">
  <h1>SHX</h1>
  <p>A fast, native SSH workspace built exclusively for macOS.</p>
  <p>
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="https://github.com/dengliang998/SHX/releases/latest">Download</a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="README.zh-CN.md">中文文档</a>
  </p>
  <p>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple">
    <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-111111?logo=apple">
    <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
    <img alt="License" src="https://img.shields.io/badge/License-Apache--2.0-blue.svg">
    <img alt="Release" src="https://img.shields.io/github/v/release/dengliang998/SHX?display_name=tag">
  </p>
</div>

![SHX connection center](docs/images/kiteshell-overview.png)

SHX combines SSH terminals, remote files, live Linux monitoring, transfers, reusable commands, and connection management in one responsive macOS application. It uses SwiftUI and AppKit for the interface, SwiftTerm for terminal rendering, and the system OpenSSH client for real SSH behavior.

## Highlights

- **Native macOS experience** — SwiftUI, AppKit, Retina rendering, system menus, keyboard shortcuts, drag and drop, notifications, light/dark appearance, and Apple Silicon binaries.
- **Real SSH terminal** — PTY-backed sessions, UTF-8, ANSI/256-color/true-color output, multiple tabs, search, reconnect policies, and configurable terminal themes.
- **Connection workspace** — favorites, recent connections, sidebar-managed groups, LAN/WAN and custom tags, batch group/tag/favorite/delete actions, search, sorting, quick connect, jump hosts, proxies, and port forwarding.
- **Chinese and English UI** — switch the application language directly in Settings without changing the macOS system language.
- **Remote files** — SFTP browsing, upload/download, folders, drag and drop, rename, move, permissions, deletion, built-in editing, external editor synchronization, and conflict detection.
- **Live server data** — real CPU, memory, swap, load, disk, network, and process data. SHX never fills disconnected views with sample server data.
- **Commands and scripts** — global and per-server libraries, variables, execution modes, risk confirmation, and recent execution metadata.
- **Local credential vault** — passwords are re-encrypted with AES-GCM in a permission-restricted local vault. They are not stored in connection JSON, logs, diagnostics, or normal exports.
- **Signed updates** — checks GitHub Releases, verifies an Ed25519-signed manifest and the DMG SHA-256, then installs through a separate rollback-capable updater helper.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon Mac
- SSH server access

SHX intentionally does not target Windows, Linux desktops, or Intel Macs.

## Install

1. Download `SHX-1.0.0.dmg` from [GitHub Releases](https://github.com/dengliang998/SHX/releases/latest).
2. Open the disk image.
3. Drag SHX into Applications.
4. Launch SHX and create a connection.

The current community build uses a stable local development signature and is not Apple-notarized. Public distribution with seamless Gatekeeper acceptance requires a Developer ID certificate and Apple notarization.

## Updates

SHX checks GitHub Releases at most once every 24 hours and also provides **SHX → Check for Updates…** and an update section in Settings.

Before replacing the application, SHX verifies:

1. the release manifest belongs to SHX;
2. the manifest has a valid Ed25519 signature;
3. the downloaded DMG matches the signed SHA-256;
4. the replacement app passes strict code-signature verification.

If replacement fails, the updater restores the previous app. See [Automatic Updates](docs/AUTO_UPDATE.md) for the full design.

## Build from source

```bash
git clone https://github.com/dengliang998/SHX.git
cd SHX
swift test
./Scripts/build-app.sh
open .build/SHX.app
```

Dependencies are pinned in `Package.resolved`.

## Test

```bash
swift test
./Scripts/run-self-tests.sh
```

The repository also includes isolated password-SSH and SFTP edit round-trip integration tests. They run against temporary local test servers and do not use production credentials.

## Privacy and security

- No terminal commands, terminal output, server addresses, or remote file contents are uploaded by default.
- Normal configuration exports never contain passwords or private-key passphrases.
- First-seen host keys are recorded by OpenSSH using `accept-new`; changed host keys are rejected.
- Update signing keys are not stored in this repository.

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability or sharing diagnostics.

## License

SHX is licensed under the [Apache License 2.0](LICENSE). Third-party components retain their respective licenses; see [Third-party Notices](THIRD_PARTY_NOTICES.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Automatic Updates](docs/AUTO_UPDATE.md)
- [Product Requirements (English summary)](docs/PRODUCT_REQUIREMENTS.en.md)
- [Product Requirements (中文完整版)](PRODUCT_REQUIREMENTS.md)
- [Release Status](IMPLEMENTATION_STATUS.md)
- [Third-party Notices](THIRD_PARTY_NOTICES.md)
- [Contributing](CONTRIBUTING.md)

## Project status

Version 1.0.0 is the first SHX release with the refreshed brand, native macOS 26 visual treatment, SSH startup fixes, and an Apple Silicon release package. Developer ID signing and Apple notarization remain release-engineering work.
