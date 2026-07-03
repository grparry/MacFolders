import AppKit

enum MainMenu {
    static func build(workspacesMenu: NSMenu) -> NSMenu {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacFolders",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacFolders",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window",
                         action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(BrowserWindowController.newWindowForTab(_:)),
                         keyEquivalent: "t")
        let newFolder = fileMenu.addItem(withTitle: "New Folder",
                                         action: #selector(ContentViewController.newFolder(_:)),
                                         keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        let getInfo = fileMenu.addItem(withTitle: "Get Info",
                                       action: #selector(AppDelegate.showItemInfo(_:)),
                                       keyEquivalent: "i")
        getInfo.target = AppDelegate.shared
        fileMenu.addItem(.separator())
        let trash = fileMenu.addItem(withTitle: "Move to Trash",
                                     action: #selector(ContentViewController.trashSelected(_:)),
                                     keyEquivalent: "\u{8}") // Cmd+Delete
        trash.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Edit (nil-target: routed via responder chain)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(ContentViewController.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(ContentViewController.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(ContentViewController.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "as Icons",
                         action: #selector(BrowserWindowController.viewAsIcons(_:)),
                         keyEquivalent: "1")
        viewMenu.addItem(withTitle: "as List",
                         action: #selector(BrowserWindowController.viewAsList(_:)),
                         keyEquivalent: "2")
        viewMenu.addItem(withTitle: "as Columns",
                         action: #selector(BrowserWindowController.viewAsColumns(_:)),
                         keyEquivalent: "3")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Show All Tabs",
                         action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let hidden = viewMenu.addItem(
            withTitle: "Show Hidden Files",
            action: #selector(ContentViewController.toggleHiddenFiles(_:)),
            keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu

        // Go
        let goItem = NSMenuItem()
        main.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Back",
                       action: #selector(BrowserWindowController.goBack(_:)),
                       keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward",
                       action: #selector(BrowserWindowController.goForward(_:)),
                       keyEquivalent: "]")
        let up = goMenu.addItem(
            withTitle: "Enclosing Folder",
            action: #selector(BrowserWindowController.goToEnclosingFolder(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = [.command]
        goMenu.addItem(.separator())
        let destinations: [(String, String, String)] = [
            ("Home", NSHomeDirectory(), "h"),
            ("Desktop", NSHomeDirectory() + "/Desktop", "d"),
            ("Documents", NSHomeDirectory() + "/Documents", "o"),
            ("Downloads", NSHomeDirectory() + "/Downloads", "l"),
            ("Applications", "/Applications", "a"),
        ]
        for (title, path, key) in destinations {
            let item = goMenu.addItem(withTitle: title,
                                      action: #selector(BrowserWindowController.goToFolder(_:)),
                                      keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]
            item.representedObject = path
        }
        goItem.submenu = goMenu

        // Workspaces
        let workspacesItem = NSMenuItem()
        main.addItem(workspacesItem)
        workspacesItem.submenu = workspacesMenu

        // Window
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Show Previous Tab",
                           action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Show Next Tab",
                           action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
