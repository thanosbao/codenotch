import Foundation
import XCTest
@testable import Codenotch

final class CodexAppServerTests: XCTestCase {
    func testRPCShapeBucketSelectionNotificationAndConnectionReuse() async throws {
        let profile = try fixtureProfile()
        let executable = try writeServer(profile: profile, source: Self.respondingServer)
        let client = CodexAppServerClient(profile: profile, executableURL: executable)

        let limits = try await client.readRateLimits()
        XCTAssertEqual(limits.accountID, "test-account")
        let windows = try CodexUsage.appServerWindows(from: limits.rateLimits)
        XCTAssertEqual(windows.first?.usedFraction, 0.49)
        let history = try CodexUsage.appServerTokenUsage(from: await client.readTokenUsage())
        XCTAssertEqual(history.dailyUsageBuckets?.first?.tokens, 12_345)
        await client.shutdown()

        let messages = try JSONSerialization.jsonObjects(at: profile.configDirectory
            .appendingPathComponent("rpc.log"))
        let requests = messages.compactMap { $0 as? [String: Any] }
        let methods = requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read",
                                 "account/usage/read"])
        let initialize = try XCTUnwrap(requests.first { $0["method"] as? String == "initialize" })
        let params = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual((params["clientInfo"] as? [String: String])?["name"], "codenotch")
        let quota = try XCTUnwrap(requests.first { $0["method"] as? String == "account/rateLimits/read" })
        XCTAssertTrue((quota["params"] as? [String: Any])?.isEmpty == true)
        let rejected = try XCTUnwrap(requests.first { $0["id"] as? String == "blocked-request" })
        XCTAssertNotNil(rejected["error"], "server-initiated actions must be rejected")
        XCTAssertEqual(try String(contentsOf: profile.configDirectory.appendingPathComponent("starts"),
                                  encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testTimedOutConnectionIsReapedAndNextReadReconnects() async throws {
        let profile = try fixtureProfile()
        let executable = try writeServer(profile: profile, source: Self.reconnectServer)
        let client = CodexAppServerClient(profile: profile, executableURL: executable, timeout: 1.5)
        do {
            _ = try await client.readRateLimits()
            XCTFail("The first response should time out")
        } catch UsageProviderError.timedOut {}

        let response: CodexRateLimitsResponse
        do {
            response = try await client.readRateLimits()
        } catch {
            let starts = try String(contentsOf: profile.configDirectory.appendingPathComponent("starts"), encoding: .utf8)
            let log = (try? String(contentsOf: profile.configDirectory.appendingPathComponent("rpc.log"),
                                   encoding: .utf8)) ?? "<no rpc log>"
            XCTFail("Reconnect failed: \(error), process starts: \(starts), requests: \(log)")
            return
        }
        XCTAssertEqual(response.accountID, "test-account")
        await client.shutdown()
        XCTAssertEqual(try String(contentsOf: profile.configDirectory.appendingPathComponent("starts"),
                                  encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    func testKeyedLimitMapWithoutCodexDoesNotFallBackToAnotherBucket() async throws {
        let profile = try fixtureProfile()
        let executable = try writeServer(profile: profile, source: Self.missingCodexServer)
        let client = CodexAppServerClient(profile: profile, executableURL: executable)
        do {
            _ = try await client.readRateLimits()
            XCTFail("A keyed response without the Codex bucket must be rejected")
        } catch UsageProviderError.badResponse(status: 0) {}
        await client.shutdown()
    }

    func testUnkeyedLimitWithExplicitNonCodexLimitIDIsRejected() async throws {
        let profile = try fixtureProfile()
        let executable = try writeServer(profile: profile, source: Self.nonCodexUnkeyedServer)
        let client = CodexAppServerClient(profile: profile, executableURL: executable)
        do {
            _ = try await client.readRateLimits()
            XCTFail("An unkeyed response identified as another model must be rejected")
        } catch UsageProviderError.badResponse(status: 0) {}
        await client.shutdown()
    }

    private func fixtureProfile() throws -> CodexProfile {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerTests.\(UUID().uuidString)")
        let config = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CodexProfile.default(home: root)
    }

    private func writeServer(profile: CodexProfile, source: String) throws -> URL {
        let executable = profile.configDirectory.appendingPathComponent("fake-codex")
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private static let respondingServer = #"""
    #!/bin/sh
    printf '1' > "$CODEX_HOME/starts"
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$CODEX_HOME/rpc.log"
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *clientInfo*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{}}'
          printf '%s\n' '{"jsonrpc":"2.0","id":"blocked-request","method":"commandExecution/requestApproval","params":{}}'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"accountId":"test-account","rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":49,"windowDurationMins":300,"resetsAt":1800001000}},"gpt-5":{"primary":{"usedPercent":99,"windowDurationMins":300}}}}}\n' "$id"
          ;;
        *account*usage*read*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"summary":{"lifetimeTokens":1234567,"peakDailyTokens":45678,"longestRunningTurnSec":540,"currentStreakDays":8,"longestStreakDays":14},"dailyUsageBuckets":[{"startDate":"2026-06-18","tokens":12345}]}}\n' "$id"
          ;;
      esac
    done
    """#

    private static let reconnectServer = #"""
    #!/bin/sh
    count=0
    [ -f "$CODEX_HOME/starts" ] && count=$(cat "$CODEX_HOME/starts")
    count=$((count + 1))
    printf '%s' "$count" > "$CODEX_HOME/starts"
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "$CODEX_HOME/rpc.log"
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *clientInfo*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
        *account*rateLimits*read*)
          if [ "$count" -eq 1 ]; then continue; fi
          printf '{"jsonrpc":"2.0","id":%s,"result":{"accountId":"test-account","rateLimits":{"primary":{"usedPercent":49,"windowDurationMins":300}}}}\n' "$id"
          ;;
      esac
    done
    """#

    private static let missingCodexServer = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *clientInfo*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"accountId":"test-account","rateLimits":{"primary":{"usedPercent":10}},"rateLimitsByLimitId":{"gpt-5":{"primary":{"usedPercent":99}}}}}'
          ;;
      esac
    done
    """#

    private static let nonCodexUnkeyedServer = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *clientInfo*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        *account*rateLimits*read*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"accountId":"test-account","limitId":"gpt-5","rateLimits":{"primary":{"usedPercent":99}}}}'
          ;;
      esac
    done
    """#
}

private extension JSONSerialization {
    static func jsonObjects(at url: URL) throws -> [Any] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try jsonObject(with: Data($0.utf8)) }
    }
}
