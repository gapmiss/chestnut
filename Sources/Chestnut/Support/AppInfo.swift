import Foundation

/// App identity shown in the right-click menu. The version is stamped into the
/// bundle's Info.plist by `make bundle` (VERSION in the Makefile is the source
/// of truth); a bare `swift build` binary has no bundle plist, hence "dev".
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Opened by Support Chestnut. Same profile the website links.
    static let supportURL = URL(string: "https://github.com/sponsors/gapmiss")!

    /// Opened by Check for Updates… — the app makes no network call of its
    /// own, so comparing versions is the browser's job and the user's.
    static let releasesURL = URL(string: "https://github.com/gapmiss/chestnut/releases")!
}
