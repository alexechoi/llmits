import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Menu bar only: no Dock icon or app menu (the bundled app also sets LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
