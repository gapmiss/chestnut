import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement covers the bundled app; this covers `swift run` on the bare binary.
app.setActivationPolicy(.accessory)
app.run()
