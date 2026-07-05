import Foundation

enum ViewMode: String, Codable {
    case icon, list, column
}

struct TabState: Codable, Equatable {
    var path: String
    var viewMode: ViewMode
    // Optionals: absent in state saved before each field existed (decode nil).
    var sidebarWidth: CGFloat?
    var expandedPaths: [String]?
    var scrollOffset: CGFloat?
    var selectedPaths: [String]?
}

struct WindowState: Codable, Equatable {
    var frame: CGRect
    var tabs: [TabState]
    var selectedTab: Int
}

struct Workspace: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var live: [WindowState]   // continuously autosaved session state
    var saved: [WindowState]  // explicit snapshot for Revert to Saved
    var favorites: [String]   // per-workspace sidebar favorites, absolute paths
    var recentFolders: [String] = []    // most-recent-first, capped
    var recentDocuments: [String] = []  // most-recent-first, capped
}

struct AppState: Codable, Equatable {
    var workspaces: [Workspace]
    /// The workspace of the most recently key window — which one is "current"
    /// for menus and which gets keyed first at launch.
    var activeWorkspaceID: UUID
    /// Workspaces with windows open; all of them restore at launch.
    var openWorkspaceIDs: [UUID] = []
}
