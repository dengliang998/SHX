import Darwin
import Foundation

final class OneTimePasswordBroker {
    let socketPath: String

    private let password: String
    private var process: Process?

    init(password: String) {
        self.password = password
        socketPath = "/tmp/shx-askpass-\(UUID().uuidString.lowercased()).sock"
    }

    func start() throws {
        cancel()

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-lU", socketPath]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [socketPath] _ in
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        try process.run()
        self.process = process

        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? input.fileHandleForWriting.close()
    }

    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit {
        cancel()
    }
}
