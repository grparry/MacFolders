# Contributing to MacFolders

Thanks for your interest. This is a personal tool opened up — contributions
are welcome, response times are best-effort.

## Building

```
brew install xcodegen
scripts/dev-run.sh    # debug build + launch
scripts/test.sh       # unit tests (required green before any PR)
```

The Xcode project is generated — edit `project.yml`, never the `.xcodeproj`.

## Ground rules

- **Fail fast.** No retry loops, no fallbacks that hide problems. Errors
  surface immediately with the real underlying `NSError`.
- **Explicit over magic.** No silent state resets; schema changes to
  `workspaces.json` go through the explicit legacy-decode migration chain in
  `WorkspaceStore.load()`.
- **Match the codebase.** Pure AppKit, no external dependencies, programmatic
  UI, comments only for what the code can't say.
- **Tests for logic.** State machines, persistence, migrations, and pure
  helpers get XCTest coverage (PascalCase method names after the `test`
  prefix). UI behavior is verified manually — describe what you did in the PR.

## Pull requests

- Branch from `main`; `main` is protected and only moves via PR with green CI.
- Keep PRs focused; one behavior change per PR.
- Describe the user-visible behavior change and how you verified it.

## Known architectural landmines (learned the hard way)

- `NSBrowser`'s drag-and-drop machinery is broken — the column view is
  custom Miller columns built from `NSTableView`s. Don't reintroduce
  `NSBrowser`.
- `NSMenuToolbarItem` swallows its menu's first item.
- FSEvents may coalesce events to an ancestor path; never assert on event
  timing, only on the path filter (`DirectoryWatcher.isRelevant`).
- The native tab bar's context menu has no public extension point — tab
  right-clicks are intercepted by an event monitor, and the clicked tab is
  found by equal-width arithmetic (`AppDelegate.installTabBarMenuMonitor`).
- Ordering front a non-selected tabbed window switches its group's
  selection to it. Front one window per tab group (the group's selected
  window), never every window.
- Modern iCloud Drive exposes undownloaded files as real-named dataless
  items, not ".name.icloud" placeholders; `isUbiquitousItem` alone reads
  everything as downloaded — use `ubiquitousItemDownloadingStatus`.
- Cross-app drag pasteboard CONTENT is unreadable during hover — reading
  URLs in `validateDrop` returns empty for external drags and the drop
  gets refused. Hover may only `canReadObject`; read content at accept.
- Many apps drag file PROMISES, not file URLs (browsers, Mail, Photos).
  Register `NSFilePromiseReceiver.readableDraggedTypes` and materialize
  at accept, or those drags are refused at the type level. Also clamp
  returned drag operations to `draggingSourceOperationMask` — an
  operation outside the source's mask refuses the drop outright.
