# KiteShell implementation and release status

Document version: 1.4

Updated: 2026-08-18

Release baseline: **KiteShell 1.1.4 (Build 114)**

KiteShell 1.1.4 refines the native interface with stronger multi-column server cards, hover-revealed actions, compact mixed-session summaries, restrained semantic color, and a stable responsive command-library header.

## Verified

- Swift unit and model tests: 43 passing, including live local-mac monitor/directory commands, partial monitor fixtures, portable hex filename parsing, text-field clipboard routing, upload progress, remote-edit synchronization, connection organization, signed/unsigned release checks, FinalShell password compatibility, and local AES-GCM vault behavior.
- Core self-tests: 6/6 passing.
- Isolated password SSH: system OpenSSH, AskPass, and PTY path passing against a temporary local server.
- Isolated SFTP editing: ControlMaster download, local modification, replacement upload, and content verification passing.
- Release app: stable `KiteShell Local Code Signing` identity and strict deep verification.
- Host keys: first-seen keys use OpenSSH `accept-new`; changed keys remain blocked.
- Connection startup: the former blocking `ssh-keyscan` and confirmation path has been removed.
- Credentials: passwords and private-key passphrases use a permission-restricted local AES-GCM vault and no longer invoke Keychain.
- FinalShell: nested JSON import and compatible `Random + MD5 + DES/ECB/PKCS5Padding` password decoding are implemented natively in Swift/CommonCrypto.
- Updates: GitHub Releases lookup, signed manifest verification, streamed DMG download, chunked SHA-256, read-only mount, independent replacement helper, strict signature verification, rollback, and relaunch are implemented. Anonymous live checks require a public GitHub release source; private-source 403/404 responses are now explained explicitly.

## Distribution boundary

The 1.1.4 community build is suitable for source and direct GitHub distribution, but it is **not Apple-notarized**. Seamless public Gatekeeper distribution still requires an Apple Developer team, a Developer ID Application certificate, Hardened Runtime configuration, and notarization.

The local credential vault protects against plaintext disclosure and other macOS users through file permissions. Because the key and ciphertext belong to the same signed-in macOS user, it does not provide Keychain or Secure Enclave-level protection against compromise of that account.

## Scope still requiring broader infrastructure

- Apple Developer ID signing, notarization, and Gatekeeper testing.
- Long-running 8/24-hour stability, multi-gigabyte transfer, and broad Linux/VPN/IPv6 matrices.
- Account-backed features such as team workspaces, cloud sync, centralized audit, or hosted AI services.
- Credentialed upstream proxy tunnels and protocol-level interrupted-transfer resume.

The detailed Chinese status from the alpha baseline is archived at [IMPLEMENTATION_STATUS.zh-CN.md](IMPLEMENTATION_STATUS.zh-CN.md).
