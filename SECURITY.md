# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting or contact the repository owner privately. Do not open a public issue containing:

- passwords, private-key passphrases, or private keys;
- server addresses, usernames, or internal network details;
- terminal output, remote paths, or downloaded files;
- update signing keys or GitHub access tokens.

Include the affected KiteShell version, macOS version, reproduction steps, expected behavior, and a minimally redacted diagnostic report.

## Security boundaries

- Credentials are stored in a local AES-GCM vault with user-only file permissions. The key and ciphertext belong to the same macOS account, so this is not equivalent to Secure Enclave or Keychain isolation against an attacker already controlling that account.
- Host keys use OpenSSH `accept-new`: new keys are recorded automatically, while changed keys are rejected.
- GitHub Release updates require both a valid Ed25519 manifest signature and a matching SHA-256 before installation.
- Current community builds are locally signed but not Developer ID signed or Apple-notarized.
