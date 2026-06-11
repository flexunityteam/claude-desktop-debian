# Design: Extend verify-patches to all patch suites

**Date:** 2026-06-11
**Status:** Approved (approach A)

## Problem

`scripts/verify-patches.sh` static-greps post-patch fingerprints from
`scripts/cowork-patch-markers.tsv` against the shipped bundle, but only
covers the Cowork patch suite (11 markers) and only one file
(`.vite/build/index.js`). Every other patch — tray, quick-window,
claude-code, org-plugins, config guards, the WCO shim in `mainView.js`,
and the frame-fix wrapper wiring in `package.json` — has no build-time
gate. A silent patch regression on an upstream bump (the #515
duplicate-icon race is the canonical example) ships to users and is only
caught later by the Playwright harness or bug reports. Local builds run
no verification at all; only CI does.

## Goals

1. Every injected patch with a stable post-patch fingerprint is verified
   at build time, in every format (deb/rpm/AppImage/Nix) and locally.
2. One source of truth: a single TSV consumed by both the verify script
   and the BATS tests (preserves the #559 design decision).
3. Backwards compatible: existing CI call sites
   (`verify-patches.sh <asar>`) keep working unchanged.

## Design

### TSV format: optional 4th column `file`

`scripts/cowork-patch-markers.tsv` is renamed to
`scripts/patch-markers.tsv` and gains an optional 4th column:

```
<name><TAB><pcre_pattern><TAB><sample>[<TAB><file>]
```

`file` is a path relative to the asar root (`app.asar.contents/`).
Empty/missing means the default `.vite/build/index.js`, so all existing
rows are valid unchanged.

### verify-patches.sh: multi-file resolution

- `load_markers` parses the 4th column into a parallel `marker_files`
  array (default `.vite/build/index.js`).
- Input resolution produces a *scan root* instead of a single file:
  - directory containing `app.asar.contents/` → root is that subdir
  - directory that itself is an asar-contents tree (has
    `.vite/build/index.js`) → root is the dir itself
  - `.asar` archive → extracted to a temp dir (already implemented);
    root is the temp dir
  - plain file (fixture/debug mode) → only markers targeting the
    default file are checked; others print `SKIP` and do not fail
- Each marker greps `<root>/<file>`; a missing target file counts as a
  MISS naming the file.

### New markers (14 rows beyond the existing 11; the planned
### `add-dir-asar-filter` already existed as `asar-adddir-filter`)

| Marker | File | Fingerprint |
|---|---|---|
| tray-mutex-guard | index.js | `if\([\w$]+\._running\)\{[\w$]+\._pending=true;return\}` |
| tray-dbus-destroy-delay | index.js | `await new Promise\([\w$]+=>setTimeout\([\w$]+,250\)\)` |
| tray-dark-icon-selection | index.js | `TrayIconTemplate-Dark\.png` |
| tray-inplace-fastpath | index.js | `\.setImage\([\w$]+\.nativeImage\.createFromPath\([\w$]+\)\);process\.platform!=="darwin"` |
| quick-window-kde-gate | index.js | `\.toLowerCase\(\)\.includes\("kde"\)` |
| claude-code-linux-platform | index.js | `"linux-arm64":"linux-x64"` |
| org-plugins-linux-path | index.js | `case"linux":return"/etc/claude/org-plugins"` |
| config-mcpservers-merge | index.js | `var _cdd_dc=JSON\.parse` |
| trusted-folder-asar-guard | index.js | `addTrustedFolder\([\w$]+\)\{if\([\w$]+\.endsWith\("\.asar"\)\)return` |
| wco-shim-inlined | mainView.js | `__claude_wco_shim` |
| autoupdater-noop-proxy | frame-fix-wrapper.js | `const autoUpdaterNoop = new Proxy\(` |
| autoupdater-linux-gate | frame-fix-wrapper.js | `prop === 'autoUpdater' && process\.platform === 'linux'` |
| entry-requires-wrapper | frame-fix-entry.js | `require\('\./frame-fix-wrapper\.js'\)` |
| package-main-entry | package.json | `"main":\s*"frame-fix-entry\.js"` |

Markers are hard requirements by design: when upstream changes shape so
a patch legitimately no longer applies, the build fails loudly and the
maintainer re-anchors the patch (or removes the row). This is the
intended trade-off — silent skip is how #515 regressed.

### build.sh wiring

After `patch_app_asar` in Phase 3, run
`"$source_dir/scripts/verify-patches.sh" "$app_staging_dir"` and abort
the build on failure. This covers all formats including Nix, and runs
in directory mode (no `npx` dependency at this point).

### BATS updates

`tests/verify-patches.bats` keeps sourcing `load_markers`. The fixture
builder writes the full `app.asar.contents/<file>` directory layout so
positive and per-marker negative tests exercise multi-file resolution.
Legacy single-file input keeps dedicated tests (index.js markers
verified, non-default markers reported as SKIP).

### Out of scope

- Verifying `claude-native-stub.js`, i18n copies, or node-pty staging
  (covered by artifact smoke tests; not regex-patched code).
- The session-restore `.asar` filter sub-patch (warn-only by design;
  the `--add-dir` filter marker covers the load-bearing path).

## Verification plan

1. `bats tests/verify-patches.bats` — all positive/negative/SKIP paths.
2. `./scripts/verify-patches.sh` against a freshly built deb's
   app.asar — all 25 markers green.
3. Full `./build.sh --build deb` — build passes with the new gate wired
   in.
4. `shellcheck scripts/verify-patches.sh`.
