import AppKit

let app = NSApplication.shared
_ = DocumentController()  // the first instance becomes NSDocumentController.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
