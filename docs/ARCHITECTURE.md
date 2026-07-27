# Architecture

KiteShell is a native macOS application with no Electron, WebView, Java, Qt, or cross-platform UI runtime.

## Layers

- **SwiftUI/AppKit interface** — connection center, workspace, inspectors, settings, sheets, menus, drag and drop, and system integration.
- **AppModel** — main-actor application state and orchestration. Expensive operations are delegated to background tasks and services.
- **SwiftTerm + PTY** — terminal rendering and interactive process hosting.
- **System OpenSSH** — SSH authentication, host-key checking, jump hosts, proxies, multiplexing, and forwarding.
- **Remote services** — SSH/SFTP-backed monitoring, file operations, transfers, and editing.
- **Persistence** — versioned JSON profiles, groups, commands, workspaces, known hosts, and a separate AES-GCM credential vault.
- **Update service** — GitHub Releases discovery, Ed25519 manifest verification, streaming SHA-256, read-only DMG mounting, and rollback-capable replacement.

## Performance rules

- No network request, blocking process wait, bulk parsing, hashing, or large file I/O on the UI thread.
- Monitoring never queues a new sample while the previous sample is unfinished.
- File transfers report bounded progress and can be cancelled.
- Terminal output remains independent from monitor and file refresh work.
- Repeated connection preflights and repeated trust scans are avoided.

