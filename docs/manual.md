# MacFolders Reference

What every part of MacFolders does. For install and build, see the
[README](../README.md).

## The workspace model

**Every window is a workspace**: a named, persistent group of tabs with its
own sidebar favorites and recent items. The window title reads
"workspace — folder".

- **New Window (Cmd+N)** creates a new workspace, auto-named "Workspace N".
  Rename it any time (Workspaces menu). Names never collide — a numeric
  suffix increments automatically.
- **New Tab (Cmd+T)** opens a tab in the current workspace.
- **All open workspaces restore at launch** — windows, tabs, the active
  tab, view mode per tab, sidebar width, expanded list-view folders,
  selection, and scroll position.
- **Live state autosaves** about a second after any change. **Save
  Workspace** additionally pins a named snapshot; **Revert to Saved**
  returns to it.
- Selecting a workspace anywhere — Workspaces menu (Ctrl+Cmd+1…9), Dock
  menu — is a *launcher*: it brings that workspace's windows forward if
  open, opens them otherwise, and never repurposes existing windows.
- The Dock menu lists workspaces above macOS's own open-window list.

### Tabs

- The tab bar is always visible.
- Open any folder in a new tab: context menu → Open in New Tab (file views
  and sidebar), or Cmd+double-click.
- **Drag a tab between windows** — dropped into another workspace's window,
  the tab joins that workspace (title, sidebar, and persistence follow).
- **Tear a tab out** into its own window and it becomes a new auto-named
  workspace.
- **Dragging a workspace's last tab away deletes that workspace.** Closing
  tabs never deletes a workspace.
- Right-click a tab: Copy Pathname, Close Tab, Move Tab to New Window.

## Views

Icon, list, column (Miller), and flat views — Cmd+1/2/3/4. Every view live-updates
as directories change on disk. Switching views and returning preserves
selection, scroll, expanded folders, and open columns.

**List view** has sortable columns: Name, Date Modified/Created/Last
Opened/Added, Size, Kind, iCloud Status, Tags, Comments. Right-click the
column header to choose which columns show; choices persist. Folders expand
in place (with live updates inside expanded folders); expansion state is
part of workspace persistence.

**Column view** supports full drag & drop, New Folder in the clicked
column, and per-column live updates.

**Flat view** (Cmd+4, the fourth view segment, or right-click any folder →
Open in Flat View; Option-click a list column header enters flat pre-sorted
by that column) shows *every file* under the folder as one sortable table —
"the biggest file anywhere in here" is one header click. A Where column
shows each file's location relative to the root; double-click it (or use
Show in Enclosing Folder) to land in list view at that folder with the file
selected. Header chips filter: a user-editable skip list (Edit List… — glob
patterns, seeded with `.*` and `node_modules`; the per-folder toggle
decides whether it applies), minimum size, and modified-within.
Right-clicking a result offers "Skip Folders Named …" to add its parent
to the list in place. All columns sort, including Where (groups files
by containing folder). **Each folder remembers its
own flat configuration** — sort and filters persist per folder, with no
save step, and never inherit between folders. Scans stream in live and
pause at a threshold (50,000 files) with the real count and a
Continue/Stop choice, instead of guessing costs up front. The subtree is
watched recursively, so results stay live.

## Sidebar

Ordered like Finder: **Locations**, **iCloud**, **Favorites**,
**Recent Folders**, **Recent Documents**.

- **Locations**: volumes (with an eject button on anything ejectable —
  drives, disk images, network mounts), SMB servers discovered on the local
  network (click to connect via the system dialog; the mounted share then
  appears as a volume), and **Trash**.
- **Trash**: browseable; right-click for **Empty Trash…**, which always
  confirms with the exact item count and empties every trash Finder would —
  home, iCloud Drive's Recently Deleted, and per-volume trashes. Requires
  Full Disk Access (see Permissions).
- **Favorites** are per-workspace. Drag folders in (at any position);
  Option-drop adds to every workspace. Right-click for Open in New Tab,
  Show in All Workspaces / Only in This Workspace, Remove. New workspaces
  inherit a copy of the creating workspace's favorites.
- **Recents** (folders and documents, most recent first, capped at 10) are
  per-workspace, exclude favorites, auto-prune dead paths, and offer
  Remove from Recents.
- Everything with a path offers **Copy Pathname**.

## Search

**Cmd+F** or the toolbar field. Results take over the content area until
you clear the field or navigate.

- **Scope starts at the current folder, always.** "This Mac" is one click
  away and never the default.
- **Name / Contents** is an explicit switch. Your mode choice persists;
  the scope deliberately resets per search.
- Folder-scoped **name** search walks the filesystem directly — it finds
  dotfiles and everything inside `.git`, `node_modules`, and other trees
  Spotlight doesn't index. **Contents** and **This Mac** searches use the
  Spotlight index.
- Results stream in with a live count (capped at 2000, stated when hit),
  support multi-selection, open on double-click (folders navigate), and
  offer Open, Show in Enclosing Folder, Copy Pathname, and Get Info.

## Files

- Full drag & drop with Finder semantics (move on same volume, Option to
  copy), including drops onto sidebar folders and in every view.
- Copy/Paste (Cmd+C/V) — and **Cut/Paste (Cmd+X/V) that actually moves**.
  Paste targets the selected folder when exactly one is selected (including
  the folder you right-clicked); otherwise the folder being viewed.
- Rename in place, Duplicate, Move to Trash (Cmd+Delete), New Folder
  (Cmd+Shift+N) targeted at the folder you clicked. Hold **Shift** while
  right-clicking and Move to Trash becomes **Delete Immediately…** —
  permanent, bypasses the Trash, always confirms with the exact count.
- **Open With**: default app labeled first, alphabetized list, versions
  shown for duplicate names, multi-selection intersection. Works on folders
  too. **Other…** opens an app picker with an explicit choice: open once,
  always for this file, or always for all files of the type — the last one
  changes the system-wide default (macOS shows its own confirmation).
- **Get Info** (Cmd+I): kind, size, location, dates, Quick Look preview,
  symlink target, and *editable* POSIX permissions.
- **Copy Pathname** everywhere: content views (multi-selection = one path
  per line; empty selection = current folder), sidebar, tabs, and Edit menu
  (Cmd+Option+C).
- Show Hidden Files (Cmd+Shift+.) is global and persistent.
- Symlinks to folders navigate in-app. Vanished folders recover to the
  nearest surviving ancestor.

## iCloud Drive

- Sidebar iCloud section (when iCloud Drive exists).
- Files not downloaded locally appear like any other file, with a dimmed
  name and accurate **iCloud Status** (In iCloud / Downloaded, with
  Finder's glyphs) in list view inside iCloud locations.
- Opening an undownloaded file starts its download; the view updates as it
  lands.
- Context menu: **Download Now**, **Remove Download** (evict a local copy;
  the file stays in iCloud), and **Keep Downloaded** (pin — checkmark shows
  the current state, interoperable with Finder's pin).

## Permissions

MacFolders is unsandboxed. macOS still gates certain folders:

- Desktop/Documents/Downloads and iCloud Drive prompt once on first access.
  Grants persist across rebuilds only if builds are signed with a stable
  identity (see README → Signing).
- **Trash requires Full Disk Access** (System Settings → Privacy &
  Security) — macOS offers no per-folder prompt for it.
- One non-public mechanism, disclosed: Keep Downloaded writes the same
  `com.apple.fileprovider.pinned#P` xattr Finder's own Keep Downloaded
  writes. There is no public API for iCloud pinning.

## State

Everything lives in
`~/Library/Application Support/MacFolders/workspaces.json` — schema changes
decode older files explicitly (fields added over time are optional), and
multi-instance runs merge through a lock-protected read-merge-write.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Cmd+N | New window (= new workspace) |
| Cmd+T | New tab |
| Cmd+W | Close window/tab |
| Cmd+F | Search |
| Cmd+1 / 2 / 3 / 4 | Icon / List / Column / Flat view |
| Cmd+I | Get Info |
| Cmd+C / X / V | Copy / Cut / Paste files |
| Cmd+Option+C | Copy Pathname |
| Cmd+Shift+N | New folder |
| Cmd+Delete | Move to Trash |
| Cmd+Shift+. | Show/hide hidden files |
| Cmd+[ / ] | Back / Forward |
| Cmd+↑ | Enclosing folder |
| Cmd+Shift+H/D/O/L/A | Home / Desktop / Documents / Downloads / Applications |
| Ctrl+Cmd+1…9 | Open workspace 1…9 |
