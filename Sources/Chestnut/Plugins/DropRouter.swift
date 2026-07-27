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
}
