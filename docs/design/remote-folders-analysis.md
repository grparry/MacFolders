# Remote Folders (SSH/Unix back-ends) — Design Analysis

**Status: PARKED** (analysis complete, not scheduled, no implementation started)
**Date: 2026-08-11**

Brainstorming analysis for connecting MacFolders to remote Unix hosts over
SSH — browse remote filesystems, transfer files, view remote files. Captured
so the decision work isn't repeated when the feature is revisited.

## Goal & v1 scope

Connect to Unix back-ends over SSH and work with their filesystems from
MacFolders. Agreed v1 scope:

- **Browse** remote directory trees.
- **View** remote files (read-only; fetch a temp copy and open/preview).
- **Transfer** files between local and remote (get/put).
- **Full remote management**: rename, delete, mkdir, chmod on the remote.
- **Deferred:** edit-in-place (fetch → edit → push on save). Not in v1.

## The core constraint

The entire app is **local-`URL` / `FileManager`-bound**. Directory listing
(`DirectoryModel` → `contentsOfDirectory`), icons (`NSWorkspace.icon(forFile:)`),
Quick Look, Open With, Get Info, drag & drop, search, and flat view all call
filesystem/workspace APIs on a **real local path**. Remote files have no local
path. This is the architectural crux, and it splits the solution space in two.

## How Finder does it (and why it doesn't help here)

Finder is **entirely mount-based**: Connect to Server hands the URL to macOS's
**NetFS** framework, a **kernel filesystem client** mounts the share under
`/Volumes/…`, and Finder then browses a normal local path. Every Finder feature
works on network files because, to Finder, they're just a mounted disk.

**But Finder only speaks protocols macOS ships a kernel client for** — SMB, AFP
(legacy), NFS, FTP, WebDAV. **It has no SSH/SFTP support.** macOS ships no SSH
filesystem, so Finder cannot browse SSH back-ends at all. Getting "Finder's way"
for SSH means supplying the missing filesystem yourself → **macFUSE + sshfs**.
That's exactly what forces the heavy dependency. The dedicated SFTP apps
(Cyberduck, Transmit, ForkLift) took the other road: implement SFTP in userspace
with their own browser, fetch-to-temp for open/edit; some add an optional FUSE
mount back for parity.

## The two approaches

### A — Native, self-contained (wrap system `sftp`/`scp`)  ← leaning

The app talks to the host itself via the system SSH tooling; stays fully
self-contained (no kext).

- **Transport:** wrap `sftp` (batch/interactive supports `ls`, `get`, `put`,
  `rename`, `rm`, `rmdir`, `mkdir`, `chmod`) and `scp`/`rsync` for bulk copies.
  Likely one persistent `sftp` subprocess per connected host for low latency.
- **Leverages the existing `~/.ssh/config` for free** — hosts, keys, ssh-agent,
  `ProxyJump`/bastions all just work; nothing to reimplement.
- **Requires a source abstraction** under the directory layer: a `FileSource`
  protocol (list / stat / read-to-temp / write / copy / rename / delete / mkdir
  / chmod) with a `LocalFileSource` (today's `FileManager` behavior) and a
  `RemoteFileSource` (sftp-backed). The big internal refactor.
- **Reduced parity for remote:** anything needing a real local path (Quick Look,
  Open With, drag to *other* apps) must **fetch-to-temp** first.
- **Fails gracefully:** a stalled connection fails a request; it never wedges
  the OS.

### B — Mount-based (app-managed macFUSE + sshfs)

Connecting mounts the host as a real local path; remote files then behave
*exactly* like local ones and **every existing feature works unchanged**, copies
are just copies. This is Finder's model. sshfs runs `ssh`, so it also honors
`~/.ssh/config`.

## macFUSE risks/costs (why B is rejected for the shipped feature)

1. **Install is a security downgrade, not a click-through.** macFUSE is a kernel
   extension. On Apple Silicon, loading it requires booting to Recovery,
   lowering the machine to **Reduced Security**, enabling user-management of
   kexts, rebooting, then approving the system extension. Permanently weakens
   boot security. Many users won't.
2. **Licensing is incompatible with an OSS/MIT app.** macFUSE 4.x is no longer
   free/open-source; can't be bundled/redistributed. Every user would have to
   install it *and* do the security dance themselves — an onboarding cliff.
3. **Stale mounts hang the system — sometimes hard.** A dropped SSH link can
   block any process touching `/Volumes` in uninterruptible sleep (beachballs,
   force-unmount, sometimes reboot). sshfs is also metadata-slow.
4. **Bus factor + OS-upgrade fragility.** macFUSE ≈ one maintainer; sshfs/libfuse
   low-maintenance; kexts break on macOS major upgrades (reinstall/re-approve
   tax). Apple's direction is **FSKit** (userspace FS framework) to kill kexts —
   so mounts are a deprecated path today, immature (no off-the-shelf FSKit
   SSHFS) tomorrow.

**Asymmetry that decides it:** for a single power user on one Mac, macFUSE is a
tolerable one-time annoyance. But **shipping** it imposes #1 and #2 on every
user of an open-source file manager, against the app's self-contained / no-magic
character.

## Recommendation

Pursue **A (native `sftp`/`scp`, self-contained)** when unparked. No kext, no
security downgrade, no license problem, reuses `~/.ssh/config`, degrades
gracefully. Cost is the `FileSource` refactor + fetch-to-temp for view/open —
real work, but contained inside the app and fully under our control.

## Open questions for when unparked

- Connection model: pick hosts from `~/.ssh/config` vs manual host/user/key
  entry (probably both; config-first).
- UI surface: remote hosts as **Locations** sidebar entries that open into a
  browsable tab (consistent with volumes/Trash).
- `FileSource` boundary: how much of the app becomes source-agnostic vs
  bridged through temp copies (icons by UTI, Get Info subset, drag semantics).
- Transfer UX: progress for large `scp`/`rsync` transfers; get/put queue.
- Connection lifecycle: persistent `sftp` session per host, reconnect, timeouts.
