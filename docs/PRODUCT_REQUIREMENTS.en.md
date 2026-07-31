# KiteShell Product Requirements — English Summary

## Product

KiteShell is a native macOS SSH workspace for developers, operators, site owners, and small technical teams. It combines reliable SSH sessions, remote files, live server monitoring, reusable commands, and transfers without fabricating disconnected data.

## Platform boundary

- macOS 14 or later
- Apple Silicon only
- Native SwiftUI and AppKit interface
- No Windows compatibility requirement
- No Electron, Flutter, Qt, or WebView shell

## Primary requirements

1. Fast and truthful password, key, Agent, LAN, Internet, and jump-host connections.
2. Multi-session terminal workspace with real PTY behavior and configurable themes.
3. Remote files that follow the terminal directory, support drag-and-drop transfer, and safely edit remote content.
4. Real Linux CPU, memory, load, disk, network, and process data from the active connection.
5. Global and per-server commands/scripts with variables and risk confirmation.
6. Local encrypted credentials that never enter normal configuration exports or logs.
7. FinalShell and OpenSSH configuration import.
8. Signed, checksum-verified updates from GitHub Releases with rollback.
9. Responsive behavior under sustained terminal output, monitoring, and transfer workloads.
10. Clear diagnostics without duplicate error surfaces.
11. Sidebar-managed groups, LAN/WAN and custom tags, batch connection organization, and in-app Simplified Chinese/English switching.

The complete Chinese product and acceptance specification is maintained in [`PRODUCT_REQUIREMENTS.md`](../PRODUCT_REQUIREMENTS.md).
