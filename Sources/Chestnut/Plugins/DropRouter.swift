import Foundation

/// Pure routing for a file drop: does it go to a plugin, or to the courier?
/// Lives outside `PetWindow` (which AppKit keeps out of the check target)
/// for the same reason as `PetGeometry` — the failure worth testing is an
/// item silently going nowhere, and every dropped URL must land in exactly
/// one place.
///
/// A plugin dispatch is a single-item affair, deliberately: plugin runs and
/// the courier contend for the same one-at-a-time surfaces — `presentPalette`
/// dismisses whatever palette and notice are up, so a plugin picker or a
/// `save` plugin's vault palette opening beside the courier's destination
/// palette clobbers one or the other. Dropping several items is a delivery;
/// the plugin path is reached by dropping the item on its own.
enum DropRouter {
    struct Route: Equatable {
        struct PluginDrop: Equatable {
            let type: PluginInputType
            let url: URL
        }
        /// Set only for a single-item drop the plugin system claims.
        let plugin: PluginDrop?
        /// Everything else, in drop order.
        let courier: [URL]
    }

    static func route(
        _ urls: [URL],
        isDirectory: (URL) -> Bool,
        hasFolderPlugin: Bool,
        hasPluginFor: (PluginInputType, String) -> Bool
    ) -> Route {
        if urls.count == 1, let only = urls.first {
            if isDirectory(only) {
                if hasFolderPlugin {
                    return Route(plugin: .init(type: .folder, url: only), courier: [])
                }
            } else if only.pathExtension.lowercased() != "md" {
                // .md drops always ride the courier.
                let ext = only.pathExtension.lowercased()
                let type = PluginDispatch.extensionToType(only.pathExtension)
                if hasPluginFor(type, ext) {
                    return Route(plugin: .init(type: type, url: only), courier: [])
                }
            }
        }
        return Route(plugin: nil, courier: urls)
    }

    static let obsidianBundleID = "md.obsidian"

    /// Whether a drop is an Obsidian drag that arrived without a path.
    ///
    /// Obsidian's file explorer drags a **folder** as its bare name on
    /// `public.utf8-plain-text` and nothing else: no file URL, no
    /// `obsidian://` link, no path, not even the vault. Measured 2026-07-29/30
    /// on three folders (8, 9 and 5 characters); the 5 was `SKILLS`, for
    /// `CLAUDE/SKILLS`, so it is the basename alone. A note or an attachment
    /// from the same explorer carries a proper `obsidian://open?vault=…&file=…`
    /// link, so this is specific to folders.
    ///
    /// A bare name is not resolvable. Searching the vaults for a directory
    /// with that name has no reliable answer, because one vault really does
    /// contain repeated folder names, and the two endings are a guess that can
    /// *move* the wrong folder, or a disambiguation prompt on most drags that
    /// asks the user for what they already knew when they started dragging.
    /// So Chestnut explains the limitation instead of acting on it, and the
    /// user drags from Finder, where the path is present.
    ///
    /// Keying on the source app is what makes this safe to divert: text cannot
    /// be dragged out of Obsidian's editor at all (the gesture extends the
    /// selection instead — established 2026-07-30), so a text-only drag from
    /// Obsidian is an explorer item, not prose. Should some other Obsidian
    /// surface drag real text, it lands here too and gets the notice rather
    /// than a text plugin; that is the known cost, and the reason this stays
    /// scoped to one bundle identifier rather than to text drags generally.
    static func isPathlessObsidianDrag(
        sourceApp: String?,
        hasFileURLs: Bool,
        hasObsidianLinks: Bool,
        hasText: Bool
    ) -> Bool {
        guard sourceApp == obsidianBundleID else { return false }
        return hasText && !hasFileURLs && !hasObsidianLinks
    }
}
