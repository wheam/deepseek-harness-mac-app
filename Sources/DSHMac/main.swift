import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)
// Top-level strong reference: NSApplication.delegate is weak.
let delegate = AppDelegate(options: options)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
