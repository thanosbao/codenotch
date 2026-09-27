import SQLite3
import XCTest
@testable import Codenotch

final class CodexProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProfileTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (directory, files) in layout {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                let path = url.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: path)
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func archive() -> UsageArchive {
        let name = "CodexProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UsageArchive(defaults: defaults)
    }

    private func writeAuth(_ profile: CodexProfile, account: String, token: String = "fake") throws {
        let claims: [String: Any] = ["email": "\(account)@example.test",
                                   "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        let auth = ["tokens": ["access_token": token, "account_id": account,
                               "id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: profile.authURL)
    }

    func testDefaultIdentityAndPathsStayCompatible() {
        let profile = CodexProfile.default(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(profile.id, "codex")
        XCTAssertEqual(profile.displayName, "Codex")
        XCTAssertEqual(profile.authURL.path, "/Users/test/.codex/auth.json")
        XCTAssertEqual(profile.stateURL.path, "/Users/test/.codex/state_5.sqlite")
        XCTAssertEqual(profile.desktopStoreURL.path, "/Users/test/.codex/sqlite/codex-dev.db")
        XCTAssertEqual(CodexLocalProvider(profile: profile).signInRoute,
                       .openApp(bundleID: "com.openai.codex", name: "Codex"))
    }

    func testDiscoveryIsStableAndIgnoresUnrelatedFiles() throws {
        let root = try home([".codex-work": ["auth.json"], ".codex-alpha": ["config.toml"],
                             ".codex-empty": [], ".codex-notes": ["README.md"],
                             ".codex-": ["auth.json"], "codex-other": ["auth.json"]])
        try Data().write(to: root.appendingPathComponent(".codex-file"))
        let found = CodexProfile.discover(home: root)
        XCTAssertEqual(found.map(\.id), ["codex", "codex-alpha", "codex-work"])
        XCTAssertEqual(found.map(\.displayName), ["Codex", "Codex (alpha)", "Codex (work)"])
        XCTAssertEqual(found[2].authURL, root.appendingPathComponent(".codex-work/auth.json"))
    }

    func testSignedOutProfilesAndMissingHomeAreSupported() throws {
        let root = try home([".codex-a": ["sessions"], ".codex-b": ["history.jsonl"],
                             ".codex-c": ["state_5.sqlite"], ".codex-d": ["sqlite/codex-dev.db"]])
        XCTAssertEqual(CodexProfile.discover(home: root).map(\.id),
                       ["codex", "codex-a", "codex-b", "codex-c", "codex-d"])
        XCTAssertEqual(CodexProfile.discover(home: root.appendingPathComponent("missing")).map(\.id),
                       ["codex"])
    }

    func testSignInNamesAndQuotesTheCorrectProfile() {
        let profile = CodexProfile(slug: "work", configDirectory: URL(fileURLWithPath: "/Users/O'Brien/.codex-work"))
        XCTAssertEqual(profile.signInCommand,
                       "CODEX_HOME='/Users/O'\"'\"'Brien/.codex-work' codex -c 'cli_auth_credentials_store=\"file\"' login")
        let provider = CodexLocalProvider(profile: profile)
        XCTAssertEqual(provider.signInRoute,
                       .guidance("Run \(profile.signInCommand) in Terminal to sign in to Codex (work)."))
        let snapshot = ProviderSnapshot(id: profile.id, displayName: profile.displayName,
                                        glyph: .openai, fidelity: .official, status: .needsAuth, windows: [])
        XCTAssertEqual(snapshot.statusMessage, "Sign in to Codex in ~/.codex-work to read your usage")
        XCTAssertNil(CodexProfile.slug(fromProviderID: "codex-"))
        XCTAssertNil(CodexProfile.slug(fromProviderID: "codextra"))
    }

    func testAccountLabelsComeFromEachProfilesCredentials() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal")
        try writeAuth(work, account: "work")
        XCTAssertEqual(CodexLocalProvider(profile: personal).account()?.label, "personal@example.test")
        XCTAssertEqual(CodexLocalProvider(profile: work).account()?.label, "work@example.test")
        XCTAssertEqual(CodexLocalProvider(profile: work).account()?.source, "Codex in \(work.displayPath)")
        try FileManager.default.removeItem(at: work.authURL)
        XCTAssertNil(CodexLocalProvider(profile: work).account(), "must never fall back to the default account")
    }

    func testOfficialServerSnapshotsStayProfileIsolated() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal", token: "personal-token")
        try writeAuth(work, account: "work", token: "work-token")
        let executable = try fakeCodexCLI(in: root)
        let archive = archive()
        let p = CodexLocalProvider(profile: personal, appServerExecutableURL: executable, archive: archive)
        let w = CodexLocalProvider(profile: work, appServerExecutableURL: executable, archive: archive)
        let personalReading: ProviderSnapshot
        do {
            personalReading = try await p.fetchSnapshot()
        } catch {
            let log = (try? String(contentsOf: personal.configDirectory.appendingPathComponent("rpc.log"),
                                   encoding: .utf8)) ?? "<no rpc log>"
            XCTFail("Personal App Server request failed: \(error), requests: \(log)")
            return
        }
        let workReading = try await w.fetchSnapshot()
        XCTAssertEqual(personalReading.id, "codex")
        XCTAssertEqual(personalReading.usedFraction, 0.10)
        XCTAssertEqual(workReading.id, "codex-work")
        XCTAssertEqual(workReading.usedFraction, 0.75)

        try writeAuth(work, account: "work", token: "rotated-token")
        let rotated = try await w.fetchSnapshot()
        XCTAssertEqual(rotated.usedFraction, 0.75)
        let unchanged = try CodexCredentials.load(from: personal.authURL)
        XCTAssertEqual(unchanged.accessToken, "personal-token")
    }

    func testMissingProfileCredentialsNeverUseAnotherAccount() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        try writeAuth(.default(home: root), account: "personal", token: "personal-token")
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        let provider = CodexLocalProvider(profile: work, archive: archive())
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("A missing work login must not return the personal reading")
        } catch UsageProviderError.needsAuth {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRPCFailureCooldownAvoidsRespawningAndKeepsFailureKind() async throws {
        let root = try home([".codex": []])
        let profile = CodexProfile.default(home: root)
        try writeAuth(profile, account: "personal", token: "personal-token")
        let executable = root.appendingPathComponent("failing-codex")
        let script = #"""
        #!/bin/sh
        count=0
        [ -f "$CODEX_HOME/starts" ] && count=$(cat "$CODEX_HOME/starts")
        count=$((count + 1))
        printf '%s' "$count" > "$CODEX_HOME/starts"
        while IFS= read -r line; do
          case "$line" in
            *clientInfo*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *account*rateLimits*read*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"unavailable"}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = CodexLocalProvider(profile: profile, appServerExecutableURL: executable,
                                          archive: archive())

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("Expected the App Server RPC error")
            } catch UsageProviderError.badResponse(status: 0) {}
        }
        await provider.signOut()
        XCTAssertEqual(try String(contentsOf: profile.configDirectory.appendingPathComponent("starts"),
                                  encoding: .utf8), "1")
    }

    @MainActor
    func testTwoProfilesKeepTheirOrderAndDisconnectIndependently() async throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try writeAuth(personal, account: "personal", token: "personal-token")
        try writeAuth(work, account: "work", token: "work-token")
        let originalAuth = try Data(contentsOf: work.authURL)
        let archive = archive()
        let executable = try fakeCodexCLI(in: root)
        let providers: [UsageProvider] = [personal, work].map {
            CodexLocalProvider(profile: $0, appServerExecutableURL: executable, archive: archive)
        }
        let store = UsageStore(providers: providers, archive: archive, order: [work.id, personal.id])
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id), [work.id, personal.id])
        XCTAssertEqual(store.providerSummaries.map(\.account?.label), ["work@example.test", "personal@example.test"])
        XCTAssertEqual(Set(archive.load().keys), Set([work.id, personal.id]))
        // Rebuilding with a disconnected profile exercises the same startup path as the app.
        let restarted = UsageStore(providers: providers, archive: archive, disconnected: [work.id])
        await restarted.refresh()
        XCTAssertEqual(restarted.snapshots.map(\.id), [personal.id])
        XCTAssertNil(archive.load()[work.id])
        XCTAssertNotNil(archive.load()[personal.id])
        XCTAssertEqual(try Data(contentsOf: work.authURL), originalAuth)
    }

    @MainActor
    func testActivityUsesEachProfilesStoreAndDistinctSessionIDs() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        try catalogue(profile: personal, title: "Personal task")
        try catalogue(profile: work, title: "Work task")
        let p = CodexActivityMonitor(profile: personal)
        let w = CodexActivityMonitor(profile: work)
        p.start(); w.start()
        defer { p.stop(); w.stop() }
        XCTAssertEqual(p.sessions.map(\.id), ["codex.desktop"])
        XCTAssertEqual(w.sessions.map(\.id), ["codex-work.desktop"])
        XCTAssertEqual(p.sessions.map(\.name), ["Personal task"])
        XCTAssertEqual(w.sessions.map(\.name), ["Work task"])
    }

    private func catalogue(profile: CodexProfile, title: String) throws {
        try FileManager.default.createDirectory(at: profile.desktopStoreURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(profile.desktopStoreURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE local_thread_catalog (source_updated_at REAL, display_title TEXT, thread_id TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO local_thread_catalog VALUES (\(Date().timeIntervalSince1970), '\(title)', 'test')", nil, nil, nil), SQLITE_OK)
    }

    private func fakeCodexCLI(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        account=personal
        percent=10
        case "$CODEX_HOME" in *".codex-work") account=work; percent=75 ;; esac
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$CODEX_HOME/rpc.log"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *clientInfo*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
            *account*rateLimits*read*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"accountId":"%s","rateLimits":{"primary":{"usedPercent":%s,"windowDurationMins":300}}}}\n' "$id" "$account" "$percent"
              ;;
            *account*usage*read*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"summary":null,"dailyUsageBuckets":null}}\n' "$id"
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    @MainActor
    func testCLIActivityWithTheSameRolloutFilenameDoesNotCollide() throws {
        let root = try home([".codex": [], ".codex-work": []])
        let personal = CodexProfile.default(home: root)
        let work = CodexProfile(slug: "work", configDirectory: root.appendingPathComponent(".codex-work"))
        for profile in [personal, work] {
            let rollout = profile.configDirectory.appendingPathComponent("rollout.jsonl")
            try Data().write(to: rollout)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(profile.stateURL.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, archived INTEGER, updated_at_ms INTEGER)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(rollout.path)', 0, 1)", nil, nil, nil), SQLITE_OK)
        }
        let p = CodexActivityMonitor(profile: personal)
        let w = CodexActivityMonitor(profile: work)
        p.start(); w.start()
        defer { p.stop(); w.stop() }
        XCTAssertEqual(p.sessions.map(\.id), ["codex.rollout.jsonl"])
        XCTAssertEqual(w.sessions.map(\.id), ["codex-work.rollout.jsonl"])
        XCTAssertEqual(w.sessions.map(\.name), ["Codex (work)"])
    }
}
