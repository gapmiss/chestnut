import Foundation

/// App identity shown in the right-click menu. The version is stamped into the
/// bundle's Info.plist by `make bundle` (VERSION in the Makefile is the source
/// of truth); a bare `swift build` binary has no bundle plist, hence "dev".
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Placeholder until the GitHub Sponsors profile is approved.
    static let supportURL = URL(string: "https://github.com/sponsors/gapmiss")!

    /// Placeholder until the repo has a public home with releases.
    static let releasesURL = URL(string: "https://github.com/gapmiss/chestnut/releases")!
}
