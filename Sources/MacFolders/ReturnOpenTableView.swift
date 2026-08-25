import AppKit

/// An NSTableView that opens the current selection on Return / keypad Enter,
/// matching double-click. Used by the flat and search-results tables (the
/// other views subclass their own base classes and add the same handling).
final class ReturnOpenTableView: NSTableView {
    var onOpenSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelection?()
        } else {
            super.keyDown(with: event)
        }
    }
}
