# MacFolders

A native macOS file manager that looks and feels like Finder — with the one
feature Finder refuses to have: **workspaces**. Every window is a named,
persistent workspace of tabs. Close the app, reopen it, and every workspace
comes back exactly as you left it.

## Why

Finder can't save and restore groups of tabs. If you work
across several projects, you rebuild your window/tab layout every day.
MacFolders makes the window itself the unit of persistence.

## Features

- **Workspaces** — each window is a workspace with its own tabs, sidebar
  favorites, and recent folders/documents. All open workspaces restore at
  launch. Live state autosaves continuously; "Save Workspace" pins a snapshot
  you can revert to.
- **Tabs as first-class citizens** — always-visible tab bar; open any folder
  in a new tab (context menu, Cmd+double-click, sidebar); drag tabs between
  windows — a tab dropped into another workspace joins it; tearing a tab out
  creates a new workspace; dragging a workspace's last tab away deletes it.
- **Four views** — icon, list (with expandable folders), Miller columns,
  and **flat view**: every file under a folder as one sortable table — the
  biggest or newest file *anywhere* in a tree is one header click away,
  with a user-editable skip list for `.git`/`node_modules`-style clutter
  and per-folder memory of how you left it. Live directory updating
  everywhere, view state preserved across toggles.
- **Everything restores** — windows, tabs, the active tab, view mode,
  sidebar width, expanded folders, selection, and scroll position, per
  workspace, on every relaunch.
- **Real file management** — drag & drop with Finder semantics everywhere
  (including drops on sidebar folders), copy/paste, **cut/paste that moves**
  (the famous Finder omission), rename in place, duplicate, trash, New Folder
  targeted at the column you clicked, and Open With that can set the
  system-wide default app for a file type.
- **Search that respects you** — Cmd+F searches the *current folder* by
  default, never your whole Mac (This Mac is one click, never the default),
  with an explicit Name / Contents switch instead of hidden token magic.
  Folder-scoped name search walks the filesystem directly, so it finds
  dotfiles and everything inside `.git` and `node_modules` — results
  Spotlight-backed Finder can't show. Content and whole-Mac searches use
  the Spotlight index.
- **iCloud Drive, properly** — sidebar section; undownloaded (dataless)
  files shown with accurate In iCloud / Downloaded status and Finder's cloud
  glyphs; open-to-download; Download Now, Remove Download, and Keep
  Downloaded (the same pin Finder sets) in the context menu.
- **List-view columns like Finder's** — Date Modified/Created/Last
  Opened/Added, Size, Kind, iCloud Status, Tags, Comments — right-click the
  header to choose which show, persisted.
- **Locations that do things** — volumes with eject buttons (drives, disk
  images, network mounts), SMB servers discovered over Bonjour with
  click-to-connect, and Trash with **Empty Trash and a real confirmation**
  that counts items across the home, iCloud, and per-volume trashes.
- **Get Info** — kind/size/where/dates, Quick Look preview, symlink targets,
  and *editable* permissions.
- **Navigation** — back/forward history, Cmd+↑, Go menu, a toolbar path
  dropdown for walking up the tree, in-app symlink following, and a global
  persistent hidden-files toggle (Cmd+Shift+.).
- Vanished-folder cleanup (tabs recover to the nearest surviving ancestor),
  dead sidebar entries auto-prune, Dock menu workspace launcher.

The complete feature reference lives in [docs/manual.md](docs/manual.md).

## Install

```
brew install xcodegen
scripts/build-install.sh     # builds Release → /Applications/MacFolders.app
```

Requires macOS 15+ and Xcode. For development: `scripts/dev-run.sh` (debug
build + launch) and `scripts/test.sh` (unit tests).

### Signing (optional but recommended)

Builds are ad-hoc signed by default, which means macOS re-asks for
Desktop/Documents/Downloads access after every reinstall. To keep those
grants across rebuilds, sign with any stable identity from your keychain:

```
export MACFOLDERS_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
```

## Security model

MacFolders is **unsandboxed** — that's what makes a general-purpose file
manager pleasant (no per-folder grant ceremony beyond the standard macOS
privacy prompts). It touches only what you navigate to, and its state lives
in `~/Library/Application Support/MacFolders/workspaces.json`. Read the
source; it's small.

Trash features need **Full Disk Access** (System Settings → Privacy &
Security) — macOS offers no per-folder prompt for `~/.Trash`. Everything
else works without it. One non-public mechanism, disclosed: Keep Downloaded
writes the same `com.apple.fileprovider.pinned#P` xattr Finder's own Keep
Downloaded writes; there is no public API for iCloud pinning.

## Status

A personal tool, opened up. It's used daily by its author, has unit tests
for the core (state, persistence and migrations, file operations), and was
built AI-pair-programmed end to end. Issues and PRs are welcome —
see [CONTRIBUTING](CONTRIBUTING.md) — but there are no support guarantees.

## License

[MIT](LICENSE)
