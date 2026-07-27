import Foundation

struct FinalShellImportPayload: Sendable {
    let profiles: [ServerProfile]
    let skippedRecords: Int
    let decodedPasswords: [UUID: String]
    let failedCredentialCount: Int
}

enum FinalShellImporter {
    static func load(urls: [URL]) async -> FinalShellImportPayload {
        await Task.detached(priority: .userInitiated) {
            var profiles: [ServerProfile] = []
            var skippedRecords = 0
            var decodedPasswords: [UUID: String] = [:]
            var failedCredentialCount = 0

            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }

                guard let data = try? Data(contentsOf: url),
                      let root = try? JSONSerialization.jsonObject(with: data) else {
                    skippedRecords += 1
                    continue
                }

                let records = connectionRecords(in: root)
                if records.isEmpty {
                    skippedRecords += 1
                }

                for record in records {
                    guard let profile = makeProfile(from: record) else {
                        skippedRecords += 1
                        continue
                    }
                    if let encodedPassword = nonEmptyString(record["password"]),
                       profile.authentication == .password {
                        if let decodedPassword = FinalShellPasswordDecoder.decode(encodedPassword),
                           !decodedPassword.isEmpty {
                            decodedPasswords[profile.id] = decodedPassword
                        } else {
                            failedCredentialCount += 1
                        }
                    }
                    profiles.append(profile)
                }
            }

            return FinalShellImportPayload(
                profiles: profiles,
                skippedRecords: skippedRecords,
                decodedPasswords: decodedPasswords,
                failedCredentialCount: failedCredentialCount
            )
        }.value
    }

    private static func connectionRecords(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            if nonEmptyString(dictionary["host"]) != nil,
               integer(dictionary["port"]) != nil {
                return [dictionary]
            }
            return dictionary.values.flatMap(connectionRecords)
        }

        if let array = value as? [Any] {
            return array.flatMap(connectionRecords)
        }

        return []
    }

    private static func makeProfile(from record: [String: Any]) -> ServerProfile? {
        guard let host = nonEmptyString(record["host"]),
              let username = nonEmptyString(record["user_name"] ?? record["username"]) else {
            return nil
        }

        let port = integer(record["port"]) ?? 22
        guard (1...65_535).contains(port) else { return nil }

        if let connectionType = integer(record["conection_type"]),
           connectionType != 100 {
            return nil
        }

        let authentication: AuthenticationMethod
        switch integer(record["authentication_type"]) {
        case 1:
            authentication = .password
        case 2:
            authentication = .privateKey
        default:
            authentication = .sshAgent
        }

        return ServerProfile(
            name: nonEmptyString(record["name"]) ?? host,
            host: host,
            port: port,
            username: username,
            authentication: authentication,
            group: "FinalShell 导入",
            notes: nonEmptyString(record["description"]) ?? ""
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
