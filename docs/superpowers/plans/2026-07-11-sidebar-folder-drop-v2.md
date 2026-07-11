# Sidebar Folder Drop v2 - wrap-up plan

Builds on the shipped v1 feature (drag a Finder folder onto the sidebar → new workspace tab). Three user asks + finish.

## Facts established (by code exploration + diagnostics)

- **Title:** with only `workingDirectory` passed, `Workspace.title` is left auto-derived and the terminal's process title (the full cwd path) shows. Passing a non-nil `title` calls `setCustomTitle`, which pins the title and blocks the process-title override (`Workspace+TitleOwnership.swift:39,136-157`). Idiom `(path as NSString).lastPathComponent` is already used in-repo (`Workspace.swift:11414`).
- **Auto-run claude:** `addWorkspace` has `initialTerminalCommand` (replaces the login shell as the PTY process, wrong here) and `initialTerminalInput` (text typed into the spawned login shell). The established "run a command, keep the shell" pattern is `initialTerminalInput: "<cmd>\n"` (`ExtensionWorktreePrototype.swift:42`). So use `initialTerminalInput: "claude\n"`.
- **Real helper cannot build on this Mac:** Zig 0.15.2 (the pinned version) fails to link against the macOS 26.5 SDK - undefined `_sigaction`/`_waitpid`/`_dispatch_*`/`_abort` - both under Xcode and standalone with `env -u SDKROOT` native compilation. Proven twice. So the real helper must be a PREBUILT universal binary.
- **Prebuilt source:** upstream release v0.64.17 ships `cmux-macos.dmg` containing `Contents/Resources/bin/ghostty` (universal). `scripts/install-prebuilt-ghostty-cli-helper.sh <helper> <app.app>` installs it (it `lipo -verify_arch arm64 x86_64`, so the source must be universal - the release binary is).
- **"DEV" name:** comes from the Debug build setting `PRODUCT_NAME = "cmux DEV"` (`project.pbxproj:7457`). Release sets `PRODUCT_NAME = cmux`, bundle id `com.cmuxterm.app` (`:7504`). `scripts/reloadp.sh` builds Release → `cmux.app`. Release still runs the helper Run Script phase and hard-fails unless the helper exists; `CMUX_SKIP_ZIG_BUILD=1` makes it a stub for both configs.

## Tasks

### Task 1: Commit the verified v1 feature
It's all uncommitted. Tests green, dev app works. Commit the feature + tests + pbxproj wiring + the Fable-fix hardening as one coherent commit on `feat/sidebar-folder-drop`. (No adversarial-review trigger: local UI wiring, no auth/db/payments/secrets.)

### Task 2: Sidebar title = folder name, and auto-run claude on drop
One edit, the `onFoldersDroppedOnSidebar` closure in `Sources/ContentView.swift`:
```swift
overlay.onFoldersDroppedOnSidebar = { [weak tabManager] directories in
    MainActor.assumeIsolated {
        guard let tabManager, !directories.isEmpty else { return false }
        for directory in directories {
            tabManager.addWorkspace(
                title: (directory.path as NSString).lastPathComponent,
                workingDirectory: directory.path,
                initialTerminalInput: "claude\n"
            )
        }
        return true
    }
}
```
- `title:` → sidebar big title shows the folder name (e.g. `myproject`), not the full path.
- `initialTerminalInput: "claude\n"` → the new tab's shell runs `claude` on open (shell survives when claude exits).
Rebuild the DEV app (`CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag dragdrop --launch`), verify by dragging a folder: tab titled with folder name, terminal launches claude. Commit.

### Task 3: Obtain the real (prebuilt) ghostty CLI helper
```bash
cd ~/Desktop/cmux-fork
gh release download v0.64.17 --repo manaflow-ai/cmux --pattern 'cmux-macos.dmg' --dir /tmp/cmux-real --clobber
hdiutil attach /tmp/cmux-real/cmux-macos.dmg -nobrowse -mountpoint /tmp/cmux-real/mnt
mkdir -p /tmp/cmux-real/helper
cp "/tmp/cmux-real/mnt/cmux.app/Contents/Resources/bin/ghostty" /tmp/cmux-real/helper/ghostty
hdiutil detach /tmp/cmux-real/mnt
file /tmp/cmux-real/helper/ghostty   # expect: Mach-O universal binary arm64 + x86_64
/tmp/cmux-real/helper/ghostty +version   # expect: prints a ghostty version, exit 0
```
If the DMG layout differs (e.g. app named `cmux.app` at root), adjust the path. If the binary is not universal or does not run, STOP and report - do not silently fall back to a stub.

### Task 4: Build the REAL app (Release) with the real helper - CORRECTED (post-Fable)

The original signing steps here were wrong and were corrected by the Fable plan
review. Fable's verified findings: hardened runtime is OFF in both configs, local
builds are ad-hoc with an empty team, and the repo's own `sign-cmux-bundle.sh`
forbids `--deep` (it triggers amfi errno 163 on macOS 26). Also, Release uses
`Resources/cmux.entitlements` (keychain-access-groups), which a plain `xcodebuild`
rejects without a development cert. So build ad-hoc with entitlements cleared,
then re-sign inside-out (no `--deep`, no `--options runtime`).

This is the exact sequence that worked:
```bash
cd ~/Desktop/cmux-fork
HELPER=<scratch>/cmux-real/helper/ghostty   # the extracted universal v0.64.17 helper

# 1. Build Release ad-hoc, entitlements cleared, DerivedData pinned. Stub helper
#    (real one can't compile: Zig 0.15.2 won't link the macOS 26 SDK).
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -project cmux.xcodeproj -scheme cmux \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build-release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="" PROVISIONING_PROFILE_SPECIFIER="" build
APP="build-release/Build/Products/Release/cmux.app"

# 2. Swap the stub for the real universal helper (script fails loud if not universal).
./scripts/install-prebuilt-ghostty-cli-helper.sh "$HELPER" "$APP"

# 3. Re-seal inside-out, ad-hoc, NO --deep, NO --options runtime.
codesign --force --sign - "$APP/Contents/Resources/bin/ghostty"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"   # "valid on disk" + "satisfies its Designated Requirement"

# 4. Install and launch.
ditto "$APP" /Applications/cmux.app
open /Applications/cmux.app
```
Verify: app is named `cmux` (bundle id `com.cmuxterm.app`, not "cmux DEV"), drag-drop
works, and `ghostty +version` in a terminal prints a real version (Ghostty 1.3.2), not
the stub. Result: installed at `/Applications/cmux.app`, runs unquarantined.

### Task 5: Docs + PR + wrap up
- Reflect the two build gotchas (pbxproj wiring; Zig 0.15.2 vs macOS 26 SDK → prebuilt
  helper) and the title/claude behavior in the docs.
- Push `feat/sidebar-folder-drop`, open PR against the fork's own `main`, CodeRabbit
  review, resolve, merge.

## Open risks - resolved by the Fable plan review
1. **Signing** - RESOLVED: hardened runtime is off, local builds are ad-hoc + unquarantined.
   No Developer-ID, no `--options runtime`, no `--deep`. Build with entitlements cleared,
   re-sign inside-out. `codesign --verify --strict` passes; app launches, no "damaged".
2. **Helper version drift** - RESOLVED: benign. `bin/ghostty` is a standalone CLI; the
   terminal renders via GhosttyKit.xcframework, no app↔helper version handshake.
3. **`initialTerminalInput: "claude\n"`** - RESOLVED: reuses the shipping `addWorkspace`
   path (same param as the SSH-URL/worktree callers); the string is fed at surface spawn,
   not raced against a live prompt. Confirmed working on first run.
4. **Multiple folders** - each opens a tab that auto-runs claude. Accepted as-is
   (user confirmed). Change to "focused only" if that becomes noisy.
5. **DerivedData path** - RESOLVED: pinned `-derivedDataPath build-release` for determinism.
