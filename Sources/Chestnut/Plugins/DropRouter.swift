import Foundation

/// Pure routing for a file drop: straight to the courier, or a choice between
/// a plugin and the courier?
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
    /// What a drop resolves to.
    ///
    /// **There is deliberately no plugin-only case.** Until 0.7 a matching
    /// plugin took the item outright and the courier never saw it, so
    /// installing a `folder` plugin removed folder delivery and installing an
    /// image plugin removed image delivery — silently, permanently, and with
    /// no gesture to say "no, deliver this one". The courier is the app's
    /// primary feature; a plugin quietly outranking it was the bug.
    ///
    /// Every URL this router sees is a file on disk, which means the courier
    /// can always take it. So whenever a plugin *also* applies, both apply,
    /// and the answer is to ask. Making the plugin-only outcome
    /// unrepresentable is what keeps a later refactor from restoring the
    /// shadowing: there is no case to fall back into.
    ///
    /// The paste path (⌃⌥C) is the one place a plugin runs unasked, and it
    /// never comes through here — its input is a temp file that gets deleted,
    /// so the courier is not a candidate at all. See `handlePluginInput`.
    enum Route: Equatable {
        struct PluginDrop: Equatable {
            let type: PluginInputType
            let url: URL
        }
        /// A single item both a plugin and the courier could handle: ask.
        case ask(PluginDrop)
        /// Straight to the courier, in drop order.
        case courier([URL])
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
                    return .ask(.init(type: .folder, url: only))
                }
            } else if only.pathExtension.lowercased() != "md" {
                // .md drops always ride the courier.
                let ext = only.pathExtension.lowercased()
                let type = PluginDispatch.extensionToType(only.pathExtension)
                if hasPluginFor(type, ext) {
                    return .ask(.init(type: type, url: only))
                }
            }
        }
        return .courier(urls)
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
