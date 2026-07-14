import Foundation

enum ViewMode: String, Codable {
    case icon, list, column, flat
}

/// Per-folder flat view configuration — each folder remembers exactly how
/// it was last flattened; folders never inherit each other's settings.
struct FlatViewConfig: Codable, Equatable {
    var sortKey: SortKey = .size
    var ascending = false
    var skipDotTrees = true      // .git, node_modules & other dot-led trees
    var minSizeBytes: Int64 = 0  // 0 = no minimum
    var modifiedWithinDays = 0   // 0 = any time
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
    /// Flat view settings keyed by folder path — app-level, since a folder's
    /// flat view is a property of the folder, not of any workspace. Optional:
    /// absent in older state files.
    var flatViewConfigs: [String: FlatViewConfig]?
}
