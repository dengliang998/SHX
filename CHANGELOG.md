# Changelog

All notable KiteShell changes are documented here. The first public release resets semantic versioning to 1.0.0. Earlier alpha builds remain summarized for historical context.

## 1.1.1 — 2026-08-11

- Add native macOS/BSD remote monitoring support and tolerate partially unavailable metrics without breaking the inspector layout.
- Replace the GNU-only remote directory listing command with a portable Linux/macOS implementation that safely preserves spaces and UTF-8 names.
- Add macOS-compatible remote file size and version checks.
- Keep terminal clipboard handling scoped to the terminal first responder so path, search, and inline edit fields receive standard Command-C/Command-V shortcuts.
- Rename remote files directly in the file list with save and cancel controls instead of opening a rename sheet.
- Constrain and simplify the empty port-forwarding layout.
- License KiteShell under Apache License 2.0.
- Set the application version to 1.1.1 (Build 111).

## 1.1.0 — 2026-07-31

- Replace free-form connection group entry with a dropdown of sidebar-managed groups; groups can only be created from the connection-center sidebar.
- Add multi-selection and batch group, tag, favorite, unfavorite, and delete actions while persisting each batch mutation once.
- Add built-in LAN and WAN tags, reusable custom tags, tag chips, and tag-aware connection search.
- Add an in-app Simplified Chinese/English switch and package both localization catalogs.
- Make the GitHub release checker injectable and cover signed newer releases, up-to-date releases, and unavailable/private release sources with automated fixtures.
- Report GitHub 403/404 update-source failures with actionable guidance instead of a generic invalid-response error.
- Set the application version to 1.1.0 (Build 110).

## 1.0.0 — 2026-07-27

- Build 101 restores reliable terminal `Command-C` / `Command-V` handling and adds Copy, Paste, and Select All to the terminal context menu.
- Establish the first public release baseline for native Apple Silicon Macs running macOS 14 or later.
- Add signed GitHub Releases updates with automatic checking, streamed downloads, Ed25519 manifest verification, SHA-256 validation, strict app-signature verification, rollback, and relaunch.
- Deliver real SSH terminals, multi-session workspaces, server monitoring, remote files, transfers, scripts, diagnostics, port forwarding, jump hosts, proxies, and safe workspace restoration.
- Import FinalShell and OpenSSH connections. Compatible FinalShell passwords are decoded natively with Swift/CommonCrypto and re-encrypted in the local AES-GCM credential vault; Java is not required.
- Keep disconnected monitoring and file views empty instead of showing sample or simulated server data.
- Improve connection latency by removing the blocking pre-connection `ssh-keyscan` path while preserving OpenSSH host-key change protection.
- Add English-first repository documentation, a Simplified Chinese README, security policy, contribution guide, architecture notes, and automatic-update documentation.
- Package KiteShell with the project icon and an independently signed updater helper.

## Pre-1.0 alpha history

The alpha series incrementally introduced the connection center, real OpenSSH sessions, password and private-key authentication, local credential storage, host-key protection, terminal themes, remote monitoring, SFTP workflows, uploads, remote editing, commands, port forwarding, diagnostics, profile import/export, and performance fixes.

For the detailed Chinese alpha history, see [CHANGELOG.zh-CN.md](CHANGELOG.zh-CN.md).
