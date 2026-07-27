import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct KiteShellSelfTests {
    static func main() async throws {
        try testModelFormatting()
        try testMonitorParser()
        try testRemoteFileParserAndPaths()
        try await testFinalShellImport()
        if let externalFixture = CommandLine.arguments.dropFirst().first {
            try await testExternalFinalShellImport(path: externalFixture)
        }
        try testOneTimePasswordBroker()
        try testLocalCredentialVaultRoundTrip()
        print("KiteShell self-tests: 6/6 passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func testModelFormatting() throws {
        let standard = ServerProfile(name: "Standard", host: "example.test", username: "user")
        let custom = ServerProfile(name: "Custom", host: "example.test", port: 2202, username: "user")
        try require(standard.displayAddress == "user@example.test", "默认端口显示错误")
        try require(custom.displayAddress == "user@example.test:2202", "自定义端口显示错误")
    }

    private static func testMonitorParser() throws {
        let fixture = """
        __UPTIME__
        90061.50 0.00
        __LOAD__
        0.12 0.34 0.56 1/100 42
        __CPU__
        0.3750
        __MEM__
        MemTotal:\t8192000
        MemAvailable:\t4096000
        SwapTotal:\t1024000
        SwapFree:\t512000
        __NET__
        123456\t654321
        __DISKS__
        /\t100000\t40000\t60000
        __PROCESSES__
        42 root sshd 1.2 0.3
        __END__
        """
        let parsed = try LinuxMonitorService.parse(fixture)
        try require(parsed.uptimeSeconds == 90061.5, "运行时间解析错误")
        try require(parsed.loadAverage == "0.12 0.34 0.56", "负载解析错误")
        try require(parsed.cpuUsage == 0.375, "CPU 解析错误")
        try require(parsed.memoryUsage == 0.5, "内存解析错误")
        try require(parsed.networkReceiveBytes == 123456, "网络接收解析错误")
        try require(parsed.disks.count == 1 && parsed.processes.count == 1, "磁盘或进程解析错误")
    }

    private static func testRemoteFileParserAndPaths() throws {
        let fixture = """
        __PWD__\t/home/demo
        __FILE__\tf\tnotes.txt\t128\t2026-07-22 10:30\t644\tdemo
        __FILE__\td\tProjects\t4096\t2026-07-21 09:00\t755\tdemo
        """
        let listing = try RemoteFileService.parse(fixture)
        try require(listing.path == "/home/demo", "远程路径解析错误")
        try require(listing.entries.count == 2, "远程文件数量解析错误")
        try require(listing.entries[0].name == "Projects" && listing.entries[0].isDirectory, "目录排序错误")
        try require(RemoteFileService.childPath(parent: listing.path, name: "Projects") == "/home/demo/Projects", "子目录路径错误")
        try require(RemoteFileService.parentPath(of: listing.path) == "/home", "父目录路径错误")
        let quotedCommand = RemoteFileService.command(path: "/tmp/a'b")
        try require(quotedCommand.contains("cd -- '/tmp/a'\"'\"'b'"), "远程路径 Shell 转义错误")
        let createCommand = RemoteFileService.createDirectoryCommand(parent: listing.path, name: "a'b")
        try require(createCommand == "mkdir -- '/home/demo/a'\"'\"'b'", "新建目录命令转义错误")
        let deleteCommand = RemoteFileService.deleteCommand(parent: listing.path, entry: listing.entries[1])
        try require(deleteCommand == "rm -f -- '/home/demo/notes.txt'", "删除文件命令错误")
    }

    private static func testFinalShellImport() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiteshell-import-\(UUID().uuidString).json")
        let fixture: [String: Any] = [
            "name": "Imported",
            "host": "import.example.test",
            "port": 2201,
            "user_name": "deploy",
            "conection_type": 100,
            "authentication_type": 1,
            "password": "eU15IxpjG1olIXZEeBsWK3AyLhO4+e3E8nqkLx+Sp77fvvwY0vmkcQ=="
        ]
        let nestedExport: [String: Any] = [
            "groups": [["name": "Imported Group", "connections": [fixture]]]
        ]
        try JSONSerialization.data(withJSONObject: nestedExport).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = await FinalShellImporter.load(urls: [url])
        try require(payload.profiles.count == 1, "FinalShell 连接导入失败")
        try require(payload.profiles[0].authentication == .password, "FinalShell 认证方式解析错误")
        let importedProfile = payload.profiles[0]
        try require(
            payload.decodedPasswords[importedProfile.id] == "KiteShell-FinalShell-Test-2026!",
            "FinalShell 加密密码解析错误"
        )
        try require(payload.failedCredentialCount == 0, "FinalShell 密码不应解析失败")
    }

    private static func testExternalFinalShellImport(path: String) async throws {
        let payload = await FinalShellImporter.load(urls: [URL(fileURLWithPath: path)])
        try require(!payload.profiles.isEmpty, "用户提供的 FinalShell 配置未解析到连接")
    }

    private static func testOneTimePasswordBroker() throws {
        let expected = "non-secret-self-test"
        let broker = OneTimePasswordBroker(password: expected)
        try broker.start()
        defer { broker.cancel() }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: broker.socketPath), Date() < deadline {
            usleep(10_000)
        }
        try require(FileManager.default.fileExists(atPath: broker.socketPath), "AskPass socket 未创建")

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", broker.socketPath]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let received = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(process.terminationStatus == 0 && received == expected, "AskPass 一次性密码通道失败")
    }

    private static func testLocalCredentialVaultRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kiteshell-local-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        let vault = LocalCredentialVault(baseDirectory: directory)
        let account = "self-test-\(UUID().uuidString)"
        let expected = Data("non-secret-local-vault-test".utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try vault.save(expected, account: account)
        let saved = try vault.read(account: account)
        try require(saved == expected, "本地凭据库读取结果不一致")
        try vault.remove(account: account)
        let removed = try vault.read(account: account)
        try require(removed == nil, "本地凭据库删除失败")
    }
}
