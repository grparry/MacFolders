# Folders — Design Spec

**Date:** 2026-07-02
**Status:** Approved (brainstorming session)

## Summary

MacFolders is a native macOS file manager that looks and behaves like Finder, with one differentiator: **switchable workspaces** — the whole app state (windows, each with tabs) is a named, persistent workspace you can swap in and out. Personal tool: unsandboxed, built locally, installed to `/Applications/MacFolders.app`.

Motivation: Finder cannot save/restore groups of tabs. No other bells and whistles wanted — the closer to stock Finder, the better.

## Requirements

- **Views:** icon view, list view (sortable columns), column view (Miller columns).
- **Sidebar:** Favorites (user-editable, per-workspace — each workspace has its own list; new workspaces inherit a copy of the active one's; amended 2026-07-02, was app-global) + Recent Folders and Recent Documents (per-workspace, most-recent-first, capped at 10, populated by navigation/opens, hidden when empty; added 2026-07-03) + Locations (mounted volumes, live-updated). Folders drag-drop into Favorites at the drop position; Option-drop adds to every workspace. Right-click on a sidebar folder offers Open in New Tab (and Remove from Sidebar for favorites).
- **Multiple instances (added 2026-07-03):** concurrent instances are supported (`open -n`). Persistence is a lock-protected read-merge-write: each instance overlays its open workspaces onto fresh disk state, so instances don't clobber each other; same-workspace is last-writer-wins. The Workspaces menu refreshes from disk on open to show other instances' workspaces.
- **Multi-workspace single instance (amended 2026-07-03, VS Code model):** one process, one Dock icon, any number of workspaces open simultaneously — each window belongs to a workspace (workspace-scoped tab groups, titles "folder — workspace", per-window sidebars). "Active" = the key window's workspace, which drives the Workspaces menu checkmark and menu-scoped actions (Save/Revert/Rename/Close/Delete). All open workspaces persist (openWorkspaceIDs) and restore at launch. Workspace selection anywhere (Dock menu, Workspaces menu, Ctrl+Cmd+1…9) is a LAUNCHER: brings the workspace's windows forward if open, opens them alongside otherwise — never repurposes existing windows. The Dock menu lists workspaces above macOS's own window switcher.
- **File operations:** copy, move, rename, duplicate, new folder, move to Trash; context menus; Open With; Cmd+C/Cmd+V of files.
- **Drag & drop:** within the app and to/from other apps, with Finder semantics (drag = move on same volume, Option = copy).
- **Tabs:** native macOS window tabs (Cmd+T), visually identical to Finder's.
- **Workspaces:** hybrid persistence model — live state continuously autosaved, plus an explicit saved snapshot with "Revert to Saved".
- **Out of scope for v1:** Quick Look, tags/labels, search, toolbar customization, iCloud sidebar section, becoming the system default file handler.
- **Post-v1 additions (2026-07-03):** Get Info panel (kind/size/where/dates, Quick Look preview, editable owner/group/everyone privileges) via right-click, sidebar, and Cmd+I; column view drag & drop (live mouse hit-testing — NSBrowser's own drop proposal machinery is broken); Cut (Cmd+X) + paste moves files, copy-fallback when the pasteboard changes.

## Approach decision

**Chosen: pure AppKit (Swift).** AppKit is what Finder is built on, so the look comes nearly free: `NSBrowser` (column view), `NSTableView` (list), `NSCollectionView` (icons), `NSOutlineView` source list (sidebar), `NSWorkspace` file icons, and native `NSWindow` tabbing (the same system tab bar Finder uses). Native tabs are also programmatically enumerable (`window.tabGroup.windows`) and restorable (`addTabbedWindow`), which the workspace feature depends on.

Rejected: SwiftUI shell with embedded AppKit views (no SwiftUI column view, weak programmatic window-tab control, would end up writing the same AppKit code plus a bridge layer); cross-platform shells (fail the "looks like Finder" requirement outright).

## Architecture

Swift + AppKit. XcodeGen-generated Xcode project. One app target. Expected zero external dependencies.

### Components

- **WorkspaceManager** (app-level, owned by AppDelegate) — owns the workspace list and active workspace, performs switches, debounce-autosaves live state, persists to disk.
- **BrowserWindowController** — one per *tab* (with native window tabbing, every tab is an `NSWindow`). Owns the toolbar (back/forward, view-mode switcher, path control), the sidebar/content split view, and per-tab navigation history.
- **SidebarViewController** — `NSOutlineView` source list. Sections: Favorites (persisted, user-editable) and Locations (mounted volumes via `NSWorkspace` mount/unmount notifications).
- **ContentViewController** — hosts one of three interchangeable view modes, all fed by the same `DirectoryModel`:
  - Icon view: `NSCollectionView`
  - List view: `NSOutlineView` — sortable columns (name, date modified, size, kind) with Finder-style expandable folders; children load lazily on expand, expansion state survives directory refreshes (amended 2026-07-02, was `NSTableView`)
  - Column view: `NSBrowser`
- **DirectoryModel** — the one source of truth per tab. Loads directory contents via `FileManager`, watches with `FSEventStream` so views update live, owns sort order and show-hidden toggle. Views are dumb renderers.
- **FileOperations** — copy/move/rename/duplicate/new folder via `FileManager`; delete = move to Trash via `NSWorkspace`. Every error surfaces immediately (see Error handling).
- **Drag & drop + pasteboard** — standard `NSPasteboard` file URLs both directions (`NSFilePromiseProvider` for drags out) so interchange with Finder, Mail, browsers, etc. works. Finder semantics for move vs copy.
- **Context menus** — Open, Open With (submenu from `NSWorkspace`), Rename, Duplicate, Move to Trash, Copy, New Folder, and "Reveal in Finder" as the escape hatch.

## Workspace model

```swift
struct Workspace: Codable {
    var id: UUID
    var name: String
    var live: [WindowState]      // continuously autosaved
    var saved: [WindowState]     // explicit snapshot
}
struct WindowState: Codable {
    var frame: CGRect
    var tabs: [TabState]
    var selectedTab: Int
}
struct TabState: Codable {
    var path: String
    var viewMode: ViewMode       // icon | list | column
}
```

Sort order and show-hidden are runtime state in `DirectoryModel` and are **not** persisted in `TabState` for v1 — a restored tab opens with default sort (name, ascending) and hidden files off. Adding them to `TabState` later is a non-breaking field addition.

Amendments (2026-07-03): `TabState` gains optional `sidebarWidth` (per-tab split position, captured as the split view's first arranged pane width and restored via `setPosition`; absent in older files decodes nil → default width). Symlinks to folders resolve and navigate in-app instead of handing off to the system. Sidebar favorites reorder via drag & drop (private pasteboard type, not a fileURL, so sidebar drags can't become file operations); favorite context menus offer context-accurate "Show in All Workspaces" / "Show Only in This Workspace" when more than one workspace exists.

### Semantics (hybrid model)

- Exactly one workspace is active; all open windows belong to it.
- Any change — tab opened/closed/navigated, window moved/resized, view mode changed — updates `live`, autosaved to disk debounced ~1 second.
- **Switch workspace:** capture current `live` → close all windows → open the target's `live` windows/tabs (create windows, `addTabbedWindow` in order, select the remembered tab).
- **Save Workspace:** copies `live` → `saved`. **Revert to Saved:** replaces `live` with `saved` and reopens.
- **Workspaces menu:** all workspaces with a checkmark on the active one; `Ctrl+Cmd+1…9` switches to the first nine (plain `Cmd+1/2/3` are the Finder-standard view-mode shortcuts); New / Rename / Delete / Save Workspace / Revert to Saved actions.
- On launch: reopen the last-active workspace's `live` state. Closing the last window does not delete the workspace.

## Persistence

Single JSON file at `~/Library/Application Support/MacFolders/workspaces.json` holding: all workspaces, active-workspace id, sidebar favorites. Written atomically.

No magic defaults: first run explicitly creates one "Default" workspace. A corrupt file shows the parse error and asks the user before starting fresh — never a silent reset.

## Error handling

Fail fast throughout:

- File operations report the actual underlying `NSError` in an alert and stop. No retries, no fallbacks.
- FSEvents/watch failures surface visibly rather than degrading silently.
- Protected folders (Desktop/Documents/Downloads) trigger one-time macOS TCC prompts (unsandboxed apps are still TCC-subject); a denial shows as a plain permission error.

## Testing

- **Unit tests (XCTest, PascalCase method names per CA1707 habit):**
  - Workspace JSON round-trip (encode/decode).
  - Switch / Save / Revert state transitions.
  - DirectoryModel sorting, filtering, hidden-files toggle against temp-directory fixtures.
  - FileOperations against temp fixtures, including error paths (e.g. rename collision).
- **UI:** manual smoke checklist for v1 — tab drag-reorder, drag/drop to external apps, workspace switch with 2+ windows. XCUITest deferred.

## Build & install

`scripts/build-install.sh`: xcodegen → `xcodebuild` (Sign to Run Locally) → copy to `/Applications/MacFolders.app`. Mirrors the existing Tabby.app local-build pattern.

## Repository

(local checkout)
