import Combine
import Foundation

/// The custom fork has no upstream update channel. The small state surface is
/// retained so the settings window can say so without carrying Sparkle.
@MainActor
final class Updater: ObservableObject {
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func start() { }
}
