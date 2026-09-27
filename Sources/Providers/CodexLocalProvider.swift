import Foundation
import SQLite3

/// Reads live account limits through the Codex-owned App Server.
actor CodexLocalProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai
    nonisolated let profile: CodexProfile

    nonisolated private let authURL: URL
    private let archive: UsageArchive
    private let appServerExecutableURL: URL?
    private var retryNoEarlierThan: Date?
    private var failureCooldownUntil: Date?
    private var failureCooldownError: UsageProviderError?
    private var appServer: CodexAppServerClient?
    private var tokenUsage: CodexTokenUsage?
    private var historyRefresh: Task<Void, Never>?
    private var historyRefreshStartedAt: Date?

    init(profile: CodexProfile = .default(),
         authURL: URL? = nil,
         appServerExecutableURL: URL? = nil,
         archive: UsageArchive = UsageArchive()) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.authURL = authURL ?? profile.authURL
        self.appServerExecutableURL = appServerExecutableURL
        self.archive = archive
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
        self.tokenUsage = archive.load()[profile.id]?.snapshot.tokenUsage
    }

    nonisolated var signInRoute: SignInRoute {
        guard profile.slug != nil else { return .openApp(bundleID: "com.openai.codex", name: "Codex") }
        return .guidance("Run \(profile.signInCommand) in Terminal to sign in to \(displayName).")
    }

    nonisolated func account() -> ProviderAccount? {
        CodexCredentials.account(from: authURL, source: profile.sourceName)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSinceNow)
        }
        let credential = try CodexCredentials.load(from: authURL)
        if let failureCooldownUntil, failureCooldownUntil > Date() {
            throw failureCooldownError ?? UsageProviderError.badResponse(status: 0)
        }
        self.failureCooldownUntil = nil
        failureCooldownError = nil
        do {
            if appServer == nil {
                appServer = try appServerExecutableURL.map {
                    CodexAppServerClient(profile: profile, executableURL: $0)
                } ?? CodexAppServerClient(profile: profile)
            }
            let response = try await appServer!.readRateLimits()
            guard response.accountID == credential.accountID else {
                throw UsageProviderError.badResponse(status: 0)
            }
            let windows = try CodexUsage.appServerWindows(from: response.rateLimits)
            retryNoEarlierThan = nil
            archive.saveBackoffUntil(nil, providerID: id)
            refreshHistoryIfDue()
            return ProviderSnapshot(
                id: id, displayName: displayName, glyph: glyph,
                fidelity: .official, status: .ok, windows: windows,
                headlineID: "primary", weeklyID: "secondary",
                tokenUsage: tokenUsage
            )
        } catch {
            if let error = error as? UsageProviderError,
               case .needsAuth = error { throw error }
            if let error = error as? UsageProviderError,
               case .credentialExpired = error { throw error }
            failureCooldownError = error as? UsageProviderError ?? .badResponse(status: 0)
            failureCooldownUntil = Date().addingTimeInterval(60)
            throw error
        }
    }

    func signOut() async {
        historyRefresh?.cancel()
        historyRefresh = nil
        await appServer?.shutdown()
        appServer = nil
    }

    private func refreshHistoryIfDue(now: Date = Date()) {
        guard historyRefresh == nil,
              historyRefreshStartedAt.map({ now.timeIntervalSince($0) >= 5 * 60 }) ?? true,
              let appServer else { return }
        historyRefreshStartedAt = now
        historyRefresh = Task { [weak self] in
            var refreshed: CodexTokenUsage?
            do {
                let data = try await appServer.readTokenUsage()
                refreshed = try CodexUsage.appServerTokenUsage(from: data)
            } catch {
                // The next successful quota read may try again after the cooldown.
            }
            await self?.finishHistoryRefresh(refreshed)
        }
    }

    private func finishHistoryRefresh(_ refreshed: CodexTokenUsage?) {
        if let refreshed { tokenUsage = refreshed }
        historyRefresh = nil
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    static var stateURL: URL {
        CodexProfile.default().stateURL
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL {
        CodexProfile.default().desktopStoreURL
    }

    /// The most recently touched desktop thread: when, and what it is called.
    static func newestDesktopThread(in url: URL) -> (title: String, updatedAt: Date)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, display_title, thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds))
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
