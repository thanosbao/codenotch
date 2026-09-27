import AppKit
import Darwin
import Foundation

struct CodexRateLimitsResponse: Sendable {
    let accountID: String
    let rateLimits: Data
}

/// One serialized stdio connection, reused across quota and history reads.
final class CodexAppServerClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vinz.codenotch.codex-app-server")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let executableURL: URL
    private let environment: [String: String]
    private let timeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bufferedOutput = Data()
    private var initialized = false
    private var requestID = 0

    init(profile: CodexProfile, timeout: TimeInterval = 12) throws {
        guard let executableURL = Self.executableURL() else {
            throw UsageProviderError.badResponse(status: 0)
        }
        self.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.configDirectory.path
        self.environment = environment
        self.timeout = timeout
        queue.setSpecific(key: queueKey, value: true)
    }

    init(profile: CodexProfile, executableURL: URL, timeout: TimeInterval = 12) {
        self.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.configDirectory.path
        self.environment = environment
        self.timeout = timeout
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopProcess()
        } else {
            queue.sync { stopProcess() }
        }
    }

    func readRateLimits() async throws -> CodexRateLimitsResponse {
        try await perform { try self.readRateLimitsSync() }
    }

    func readTokenUsage() async throws -> Data {
        try await perform { try self.readTokenUsageSync() }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopProcess()
                continuation.resume()
            }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch {
                    self.stopProcess()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readRateLimitsSync() throws -> CodexRateLimitsResponse {
        try initializeIfNeeded()
        let result = try request("account/rateLimits/read")
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let accountID = object["accountId"] as? String else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let rateLimits: [String: Any]
        if object["rateLimitsByLimitId"] != nil {
            guard let buckets = object["rateLimitsByLimitId"] as? [String: [String: Any]],
                  let codex = buckets["codex"] else {
                throw UsageProviderError.badResponse(status: 0)
            }
            rateLimits = codex
        } else if let unkeyed = object["rateLimits"] as? [String: Any] {
            for value in [object["limitId"], unkeyed["limitId"]].compactMap({ $0 }) {
                guard value is NSNull || (value as? String) == "codex" else {
                    throw UsageProviderError.badResponse(status: 0)
                }
            }
            rateLimits = unkeyed
        } else {
            throw UsageProviderError.badResponse(status: 0)
        }
        guard JSONSerialization.isValidJSONObject(rateLimits) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return CodexRateLimitsResponse(
            accountID: accountID,
            rateLimits: try JSONSerialization.data(withJSONObject: rateLimits)
        )
    }

    private func readTokenUsageSync() throws -> Data {
        try initializeIfNeeded()
        return try request("account/usage/read")
    }

    private func initializeIfNeeded() throws {
        if initialized, process?.isRunning == true { return }
        stopProcess()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        bufferedOutput.removeAll(keepingCapacity: true)
        requestID = 0

        _ = try request("initialize", params: [
            "clientInfo": ["name": "codenotch", "title": "Codenotch", "version": "1.0"]
        ])
        try write(["jsonrpc": "2.0", "method": "initialized"])
        initialized = true
    }

    private func request(_ method: String, params: [String: Any] = [:]) throws -> Data {
        requestID += 1
        let id = requestID
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = try readLine(until: deadline)
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageProviderError.badResponse(status: 0)
            }
            if let method = message["method"] as? String {
                if method == "account/rateLimits/updated" { continue }
                if let serverID = message["id"] {
                    try write(["jsonrpc": "2.0", "id": serverID,
                               "error": ["code": -32601, "message": "Method not supported"]])
                }
                continue
            }
            guard (message["id"] as? Int) == id else { continue }
            if message["error"] != nil { throw UsageProviderError.badResponse(status: 0) }
            guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
                throw UsageProviderError.badResponse(status: 0)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
        throw UsageProviderError.timedOut
    }

    private func write(_ value: [String: Any]) throws {
        guard let input else { throw UsageProviderError.badResponse(status: 0) }
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func readLine(until deadline: Date) throws -> Data {
        while true {
            if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                let line = bufferedOutput[..<newline]
                bufferedOutput.removeSubrange(...newline)
                return Data(line.last == 0x0D ? line.dropLast() : line)
            }
            guard let output else { throw UsageProviderError.badResponse(status: 0) }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            guard ready > 0 else {
                if ready == 0 { throw UsageProviderError.timedOut }
                throw UsageProviderError.badResponse(status: 0)
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { throw UsageProviderError.badResponse(status: 0) }
            bufferedOutput.append(contentsOf: bytes.prefix(count))
            guard bufferedOutput.count <= 1_048_576 else {
                throw UsageProviderError.badResponse(status: 0)
            }
        }
    }

    private func stopProcess() {
        if let process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        initialized = false
        bufferedOutput.removeAll(keepingCapacity: false)
    }

    private static func executableURL() -> URL? {
        let workspace = NSWorkspace.shared
        for bundleID in ["com.openai.chat", "com.openai.codex"] {
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let cli = appURL.appendingPathComponent(
                "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            )
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        }
        return nil
    }
}
