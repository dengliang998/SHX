# Changelog

All notable KiteShell changes are documented here. The first public release resets semantic versioning to 1.0.0. Earlier alpha builds remain summarized for historical context.

## 1.0.0 — 2026-07-27

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
