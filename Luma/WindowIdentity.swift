import AppKit
import SwiftUI

@MainActor enum LumaWindowIdentity {
    static let library = NSUserInterfaceItemIdentifier("dev.patrick.Luma.library")

    static func libraryWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == library && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }
}

/// Identify the actual WindowGroup window instead of guessing from its title
/// or accidentally treating Preferences and file panels as library windows.
struct LibraryWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MarkerView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { view.window?.identifier = LumaWindowIdentity.library }

    private final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = LumaWindowIdentity.library
        }
    }
}
