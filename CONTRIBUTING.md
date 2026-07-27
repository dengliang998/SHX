# Contributing to KiteShell

KiteShell targets macOS 14+ on Apple Silicon and is implemented with SwiftUI, AppKit, SwiftTerm, and the system OpenSSH tools.

## Before submitting a change

1. Keep server, file, monitor, and connection states truthful. Do not introduce sample production data.
2. Keep network, parsing, cryptography, hashing, and large file I/O off the main thread.
3. Never add real credentials, server addresses, private keys, or unredacted screenshots.
4. Preserve compatibility with existing profile and workspace data.
5. Run:

```bash
swift test
./Scripts/run-self-tests.sh
```

Changes to SSH, SFTP, credentials, updates, or remote editing should also run the relevant isolated integration test under `Scripts/`.

## Style

- Prefer native macOS controls and behavior.
- Keep user-facing errors actionable and avoid duplicate alerts.
- Use bounded concurrency and cancellable background tasks.
- Document security or migration tradeoffs in the pull request.

