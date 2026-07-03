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
- **Three Finder-style views** — icon, list (with expandable folders), and
  Miller columns — with live directory updating in every view, view state
  preserved across toggles, and per-tab sidebar widths.
- **Real file management** — drag & drop with Finder semantics everywhere
  (including drops on sidebar folders), copy/paste, **cut/paste that moves**
  (the famous Finder omission), rename in place, duplicate, trash, New Folder
  targeted at the column you clicked.
- **Get Info** — kind/size/where/dates, Quick Look preview, symlink targets,
  and *editable* permissions.
- **Navigation** — back/forward history, Cmd+↑, Go menu, a toolbar path
  dropdown for walking up the tree, and in-app symlink following.
- Vanished-folder cleanup (tabs recover to the nearest surviving ancestor),
  dead sidebar entries auto-prune, Dock menu workspace launcher.

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

## Status

A personal tool, opened up. It's used daily by its author, has unit tests
for the core (state, persistence and migrations, file operations), and was
built AI-pair-programmed end to end. Issues and PRs are welcome —
see [CONTRIBUTING](CONTRIBUTING.md) — but there are no support guarantees.

## License

[MIT](LICENSE)
