import Foundation

/// Pure routing for a multi-item file drop: which single item goes to a
/// plugin, and everything else to the courier. Lives outside `PetWindow`
/// (which AppKit keeps out of the check target) for the same reason as
/// `PetGeometry` — the failure worth testing is an item silently going
/// nowhere, and every dropped URL must land in exactly one place.
///
/// One plugin dispatch per drop, deliberately: plugin runs drive shared
/// surfaces (the chewing pose, the capture panel, the picker palette), so
/// fanning a drop out into several concurrent runs would pile those on top
/// of each other. The first eligible item keeps its single-drop behavior;
/// the rest ride the courier rather than vanishing.
enum DropRouter {
    struct Route: Equatable {
        struct PluginDrop: Equatable {
            let type: PluginInputType
            let url: URL
        }
        /// At most one item is dispatched to a plugin per drop.
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
        if hasFolderPlugin, let dir = urls.first(where: isDirectory) {
            return Route(
                plugin: .init(type: .folder, url: dir),
                courier: urls.filter { $0 != dir }
            )
        }
        // Only the first non-.md item is consulted for plugin dispatch,
        // matching single-drop behavior; .md files always ride the courier.
        let nonMD = urls.filter { $0.pathExtension.lowercased() != "md" }
        if let first = nonMD.first {
            let ext = first.pathExtension.lowercased()
            let type = PluginDispatch.extensionToType(first.pathExtension)
            if hasPluginFor(type, ext) {
                return Route(
                    plugin: .init(type: type, url: first),
                    courier: urls.filter { $0 != first }
                )
            }
        }
        return Route(plugin: nil, courier: urls)
    }
}
