# cmux NEXT bundle size: from 205 MB to "100x smaller"

Written 2026-10-20 by a Chief subagent. Request: user msg 3422 ("decrease the
bundle size of cmux-next by 100x ... from first principles ... we have a lot of
Mac minis and Linux machines").

Tools: `scripts/cmux-next/bundle-size.py report|check` and the ratchet
`scripts/cmux-next/bundle-size-budget.json`. The nightly-next arm64 job runs the
check after the DMG smoke ("Bundle size budget" in `.github/workflows/nightly.yml`).
The step does not block the publish yet.

## 1. Where we are (measured, not estimated)

The latest nightly-next arm64 is `cmux-nightly-next-macos-arm64.dmg`, published
2026-10-20 at 02:12Z. Its DMG is 205.4 MB (LZMA, ULMO). The installed app is
664.8 MB. The DMG was 185.7 MB on 2026-10-14, so it grew 10% in 6 days. The
whole app is already arm64-only and stripped.

| Component | On disk | In DMG (xz -6 est.) | Share of DMG |
|---|---:|---:|---:|
| `Frameworks/Chromium Embedded Framework.framework` | 347.2 MB | 103.2 MB | 58% |
| &nbsp;&nbsp;framework binary (arm64, stripped, **non-official build**) | 270.2 MB | 71.5 MB | |
| &nbsp;&nbsp;`resources.pak` (already gzip/brotli/FLAC inside) | 20.3 MB | 20.1 MB | |
| &nbsp;&nbsp;`libvk_swiftshader.dylib` | 16.0 MB | 4.0 MB | |
| &nbsp;&nbsp;`icudtl.dat` | 10.8 MB | 3.4 MB | |
| &nbsp;&nbsp;22 locale `.lproj` (trimmed to our 21 languages then; since 2026-10-28 all 228 ship: 52.8 MB, 8.4 MB xz) | 17.4 MB | 3.0 MB | |
| &nbsp;&nbsp;`chrome_100/200_percent.pak`, `CREDITS.html`, shader cache, V8 snapshot | 12.0 MB | 2.6 MB | |
| `Resources/bin` (Rust `cmux` 68 MB = cmux-tui + acpmux; optchat-chief 10 MB; ghostty 5.7; browser-host 5; tui-host 2.7; cloud 1.9; app-host 1.7) | 98.5 MB | 29.3 MB | 16% |
| `MacOS/cmux` (Swift app, 74 MB `__text`) | 98.1 MB | 27.3 MB | 15% |
| `Library/cmux Computer Use.app` | 13.9 MB | 4.3 MB | 2% |
| `Resources/markdown-viewer` (Monaco, shiki 253 grammars, mermaid, vega) | 22.4 MB | 3.8 MB | 2% |
| `Resources/Extensions` (uBlock Origin) | 15.5 MB | 3.3 MB | 2% |
| `Resources/cmux-symbols.bin` (in-app symbolication) | 2.9 MB | 2.9 MB | 2% |
| React page bundles (Pages, AgentPane, Design, Settings, ...) | ~30 MB | ~6 MB | 3% |
| Sentry.framework | 9.7 MB | 1.5 MB | 1% |
| everything else | ~26 MB | ~4 MB | 2% |

Where the 74 MB of Swift `__text` goes, from `cmux-symbols.bin`:
- About 10 MB is Rust linked into the app: iroh, noq, h2, tokio, rustls,
  serde, uniffi, the layout reducer and the tasks core. tokio, rustls and h2
  are also in `bin/cmux`, so these ship twice.
- About 2.2 MB is spirv_cross and glslang, from Ghostty.
- The largest Swift modules are CmuxNextApp 8.8 MB, CmuxNextDaemon 3.7,
  CmuxNextBrowser 2.5, Sidebar 2.0, CmuxIrohTransport 1.9, CmuxNextDesign
  1.9, MessagesLabHome 1.8, AgentPane 1.7 and CmuxIrxTransport 1.3.

### Earlier size work, and what grew back

I found no earlier 100x cut in git, docs or plans. The work before this was
bead cx-b6r7 plus older commits:
- Linux SSH payloads download on demand instead of shipping in the app
  (−77 MiB, 85dbde2ec8b / 18d96ed2069).
- LZMA DMG.
- Full strip of cmux's own executables (−13.7 MB), and of every helper
  (−3.4 MB).
- Fat LTO for cmux-tui (−11.1 MB).
- `-dead_strip`.
- Unused CEF locales trimmed (#16732); undone 2026-10-28: every language ships (chromium-slim.md).
- CEF dylibs stripped (−7 MiB).
- Strings tables as binary plists (−10 MiB).
- `-no_exported_symbols` plus `cmux-symbols.bin` (−11 MiB).
- Earlier: #7589.

None of that work had a byte budget. This plan adds one. Growth since
2026-10-14 is spread across many parts (+20 MB DMG): MacOS/cmux +4.6 MB,
bin/cmux +3.5 MB, the React pages, and markdown-viewer.

## 2. What 100x means

100x of the 205 MB DMG is about 2 MB. 100x of the 665 MB app is about 6.6 MB.
Even with every optional part removed, the Swift app alone is 27 MB in the
DMG, so no single-binary app reaches 100x. Only one design gets there:

**A ~2 MB bootstrap that downloads what you use.** The DMG and the first
install hold just the core: the Swift app, the daemon, the terminal and
WebKit browsing. Chromium, uBlock, Computer Use, the Markdown/Monaco editor
pages and the Chief binary each come as a signed, notarized, sha256-pinned
component the first time a feature needs it. The app already has the seams
for this:
- `CEFRuntimeLayout.locate` reads the CEF runtime from
  `CMUX_NEXT_CEF_RUNTIME`.
- When CEF is missing, `BrowserEngineResolver` opens the tab in WebKit with
  a `CEFUnavailableReason`.
- `ssh_artifacts.rs` is a pinned on-demand downloader that already ships.

The realistic targets, measured on the DMG:

| Stage | DMG | vs today |
|---|---:|---:|
| today | 205 MB | 1x |
| A. safe cuts (this change + official CEF + trims below) | ~165 MB | 1.25x |
| B. Chromium as an on-demand runtime (core app ships without CEF) | ~65 MB | 3x |
| C. all optional components on demand + size-tuned binaries | ~35-40 MB | 5-6x |
| D. bootstrap DMG (core downloads too) | ~2 MB | **100x** of the download; the installed app is still C |

D gets 100x on the download only, not on the installed app. Each stage
below lists its risk.

## 3. First-principles inventory: what each feature needs

| Feature | Needs | Can it be on demand? |
|---|---|---|
| Terminals, panes, sidebar, Home | MacOS/cmux, `bin/cmux` (daemon), ghostty resources, terminfo | no (core) |
| Browser, WebKit | macOS's WebKit: 0 bytes | — |
| Browser, Chromium (extensions, 1Password/Bitwarden, Chrome parity, DRM via Widevine) | CEF framework, shim, 5 helpers, uBlock | **yes**: WebKit until it is installed |
| Markdown, diff, editor pages | markdown-viewer/webviews-app (Monaco, shiki, mermaid/Ondine) | partly: shiki grammars and Monaco languages already load lazily per file; they could be fetched |
| Agent pane, Settings, Home pages (React) | page bundles | no, they are small (6 MB in the DMG) |
| Chief (Home) | optchat-chief | yes (DEV/NIGHTLY only today) |
| Computer Use | `Library/cmux Computer Use.app` | yes: onboarding installs it |
| `cmux run` code mode | code-mode SDK + catalogs | no, 0.2 MB in the DMG |
| Crash reports | Sentry.framework, cmux-symbols.bin | no |
| Updates | Sparkle | no |

## 4. Cuts, in order of size and risk

Savings are in the DMG / on disk. "Done" means pushed to feat-cmux-next.

| # | Cut | DMG | Disk | Risk | Status |
|---|---|---:|---:|---|---|
| 1 | Remove LC_ATOM_INFO (mergeable-library link data) from bundled frameworks; Sentry 9.7 → 3.1 MB, all symbols kept | −0.85 MB | −6.6 MB | none: dyld never reads it; dlopen and all 281 ObjC classes check out | **done** (655b4a9f2ee) |
| 2 | Byte budget + ratchet in CI and nightly | — | — | none (non-blocking) | **done** |
| 3 | V8 snapshot of the other arch in arm64 builds | −0.2 MB | −0.76 MB | none | already gone in today's artifact; the budget forbids it from coming back |
| 4 | **Official CEF build** (`is_official_build=true`: ThinLTO, ICF, no debug-only paths; same feature switches) | est. −15 to −25 MB | est. −60 to −90 MB | low. It is the config Google ships. Build is much longer; A/B speed too | **building**: fork `cmux/8037-cmux28-official` af04123c56e, fleet job 70436914a38e |
| 5 | Chromium as an on-demand runtime: notarized `cef-runtime-<ver>.tar.xz` (framework + shim + helpers + uBlock), installed to `~/Library/Application Support/cmux/cef/<sha>`, found by `CEFRuntimeLayout.locate`; WebKit until it is there; prefetch in the background after first launch | **−103 MB** | **−363 MB** | medium. Library validation (same Team ID: fine). The helper apps sit outside the app bundle. Updates are version-pinned per app build. The first Chromium tab can wait about 10 s on a fast link. The default engine is Chromium, so first-run UX needs a design | design; next agent |
| 6 | Computer Use helper on demand (onboarding already gates it) | −4.3 MB | −13.9 MB | low | design |
| 7 | optchat-chief on demand (Home Chief) | −3 MB | −10 MB | low | design |
| 8 | Rust `bin/cmux` size pass: `cargo bloat --crates` on the fleet, then `opt-level="s"` for cold crates only (keep 3 for the hot render/daemon path), split rquickjs (code mode) out | est. −5 to −8 MB | −15 to −25 MB | medium: speed. Needs the perf bench (a153/a168) before and after | measure first |
| 9 | Dedupe Rust in the app: about 10 MB of iroh/tokio/rustls/h2 is linked into MacOS/cmux and again into bin/cmux. Move transport into the daemon, or share one dylib | est. −3 MB | −10 MB | medium: architecture | design |
| 10 | Swift `-Osize` for cold packages (Settings, Onboarding, Pages glue, MessagesLab) | est. −3 to −5 MB | −10 to −15 MB | low-medium: keep `-O` on hot paths (terminal, tabs, sidebar) | measure first |
| 11 | resources.pak (20 MB, does not compress). It carries about 4.7 MB of FLAC audio and the WebUI/DevTools frontends. Map resource IDs to names with the fleet tree's grit headers, then drop what cmux never shows (`enable_resource_allowlist_generation`, `optimize_webui`) | est. −5 to −8 MB | same | medium: keep DevTools, PDF and extensions UI | measure on the fleet tree |
| 12 | `libvk_swiftshader` (16 MB): software WebGL fallback | −4 MB | −16 MB | medium: GPU-less VMs and blocklisted GPUs lose WebGL. **Kept** | kept |
| 13 | ICU data trim to our 21 languages (`icu_use_data_file` + filter) | −1.5 MB | −5 MB | medium: `Intl` in web pages for other locales | later |
| 14 | markdown-viewer: fetch shiki grammars and Monaco NLS on first use; drop `highlight.min.js` / `github-markdown.css` if the iOS copy and dev host stop using them | −1 to −2 MB | −8 MB | low | later |
| 15 | Bootstrap DMG (stage D) | −~200 MB download | — | high: first launch needs a network; offline install breaks | last |

What I kept, and why:
- Widevine. Spotify DRM was verified working on CEF (browser.md §6).
- PDF viewer, printing and DevTools. Users and agents use them.
- Extensions and uBlock. They are product features.
- All 228 CEF locale catalogs (chromium-slim.md, Lawrence 2026-10-28: keep every language).
- swiftshader. It is the WebGL fallback.
- `gpu_shader_cache.bin`. It makes first paint faster.
- CREDITS.html and the license folders. Licenses are required, and they
  compress to almost nothing.
- `cmux-symbols.bin`. In-app hang symbolication needs it.
- The 5 identical helper apps. Chromium needs distinct helper bundles, and
  each one's signature names it.
- I found no old React UI in acpmux. It embeds one 104 KB plain HTML page.
- No node_modules, source maps, dSYMs or x86_64 slices ship (the budget
  forbids them).

## 5. Next steps (owners to assign)

1. When fleet job 70436914a38e finishes, measure the official framework
   with `bundle-size.py report` on a DEV app built against it. If the win
   holds, apply the same args to `cmux/8037-cmux29-rc` (the browser lane owns
   the CEF pin). Then lower the CEF cap.
2. Stage B, Chromium on demand. This is the biggest single cut (−50% of the
   DMG). It needs a design pass on first-run UX (WebKit until Chromium is
   ready, or a progress tab), then failing-first tests. Use the
   `CEFRuntimeLayout.locate` seam, add a runtime-pack publish to the CEF
   release flow, and do the download and verify the way `ssh_artifacts.rs`
   does.
3. Measure #8 and #10 on the fleet, and run the perf bench before choosing
   any opt-level.
4. Make the nightly budget step blocking once two nightlies pass it.

## 6. Stage B design: Chromium on demand (cut #5)

Written 2026-10-20 by the Chief subagent that builds stage B (user msg 3422,
Chief task "Chromium download on first use"). Goal: the DMG ships without the
Chromium engine (−103 MB of DMG, −363 MB on disk), and the app installs the
engine the first time it is needed, or in the background soon after the first
launch.

### 6.1 What moves out of the app

The **runtime pack** holds everything `embed-cef.sh` puts in
`Contents/Frameworks` for Chromium, already signed by `sign-cef.sh`, in one
flat folder:

    <Product> Chromium/                           the runtime folder (not a bundle)
      Chromium Embedded Framework.framework
      libcmux_cef_shim.dylib
      <Product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
    cef-runtime.json                              the pack's own metadata

uBlock Origin (`Resources/Extensions`, 3.3 MB DMG) stays in the app for now:
it is not part of the engine and it has its own cap.

Why this shape:
- The helpers load the framework through `CefScopedLibraryLoader::LoadInHelper`,
  which takes the path `../../../Chromium Embedded Framework.framework`
  relative to the helper. The helpers must sit beside the framework.
- Chromium finds the (GPU)/(Renderer)/(Plugin)/(Alerts) helper variants beside
  the base helper (`browser_subprocess_path`).
- The helper sandbox (`no_sandbox = false`) starts before the helper loads the
  framework. It lets a helper read the `bundle-path` parameter, which is
  `base::apple::MainBundlePath()`: the real app, not CEF's `main_bundle_path`.
  **Finding (DEV experiment, 2026-10-19):** with the runtime outside the app,
  every helper failed with "file system sandbox blocked open()" and the browser
  hit FATAL "GPU process isn't usable". Fix: the CEF fork patch
  `cmux_runtime_outside_bundle` (manaflow-ai/cef, branch
  `cmux/8037-cmux28-ondemand`) sets the `component-path` parameter, which
  `common.sb` already allows to read, to the framework's parent folder when
  that folder is outside the main bundle. Inside the bundle nothing changes.
- **Second finding (same day, patched CEF):** a wrapper `.app` around the
  runtime (`<Product> Chromium.app/Contents/Frameworks`) as CEF's main bundle
  fails: the helper reads the wrapper's `Contents/Info.plist`, which is outside
  the readable folder ("Failed to load the bundle"). The flat folder with the
  app as the main bundle works: Chromium reached `ready`, renderers ran from
  the folder and a page loaded, with no sandbox errors. So the app stays
  Chromium's main bundle (bundle id, Mach rendezvous names and notification
  identity do not change) and the pack has no wrapper.
- `CEFRuntimeLayout.at(_:fallbackMainBundle:)` builds the layout: for a folder
  that is not inside an `.app`, the main bundle is the app itself.
- Profile data is under `CEFProfileStorage` (an explicit root, keyed by the
  app's bundle id), so cookies, logins and extensions stay where they are.
- Library validation: every cmux entitlements file has
  `com.apple.security.cs.disable-library-validation`, and the pack is signed by
  the same team anyway.
- The app can use on-demand Chromium only with a CEF artifact that has the
  patch (the fleet build `cef-154-0-28-cmux-28-ondemand` has it).

### 6.2 Identity, pin and reuse

- **Pack key** = first 16 hex of sha256 over: the CEF artifact sha256
  (`cef-manifest.json`), the embed `LAYOUT`, the shim build key, the product
  name, the bundle id and the signing team. It changes only when one of
  those changes (a CEF bump, a shim change, a new channel), not on every
  nightly. A nightly whose key is already published reuses that pack: it
  downloads the published pin, checks it, and does not upload anything.
  Users therefore download Chromium again only when the engine changed.
- **Pin**: `Contents/Resources/cef-runtime.json` in the signed app:
  `{schema, key, cef, chromium, shim_abi, sha256, size, url, team_id, folder}`.
  The pin is inside the app's code signature, so the sha256 it names is as
  trusted as the app. This is the "signature" of the pack.
- **Hosting**: the existing cmux-next nightly R2 bucket and domain
  (`cmux-nightly-next`, `https://files-next.cmux.com`), key
  `cef-runtime/<key>/<asset>`, uploaded write-once (`If-None-Match: *`) by
  the publish job **before** the appcast that points at the app goes up.
  No new service or account; R2 has no egress fee; storage is about 0.1 GB
  per engine change. Stable releases use the same scheme under their own
  prefix when stable ships cmux-next.

### 6.3 Install on the Mac

`CmuxNextChromiumRuntime` (new leaf module: Foundation, Security, Network; no
UI) owns it. `ChromiumRuntimeInstaller` is an `actor`:

1. **Where**: `~/Library/Application Support/<bundle id>/ChromiumRuntime/<key>/`
   holds the runtime folder and `installed.json` (the pin it was checked against).
   An install is complete only when `installed.json` exists; it is written
   last, after an atomic `rename` of the staging folder.
2. **Download**: `<root>/.downloads/<key>.tar.xz.partial`. A retry sends
   `Range: bytes=<size>-`; a 206 appends, a 200 starts again. The file is
   kept across launches, so a partial download resumes after a quit, a crash
   or a network change.
3. **Verify**: size and sha256 of the whole file must match the pin, else the
   partial file is deleted and the attempt counts as failed.
4. **Unpack**: `/usr/bin/tar -xJf` into `<root>/.staging-<uuid>`; any entry
   with an absolute path or `..`, any entry outside the runtime folder, any
   symlink that points outside the pack, or a missing framework, shim or base
   helper fails the install. Then the code signature of the
   framework, the shim and every helper is checked
   (`SecStaticCodeCheckValidity`, strict, nested code) against
   `anchor apple generic and certificate leaf[subject.OU] = "<team_id>"` when
   the pin names a team (release builds). Dev builds (ad hoc) skip only this
   check; the sha256 pin still applies. Quarantine attributes are removed.
5. **Activate**: rename staging to `<key>/`, write `installed.json`.
6. **Clean up**: other `<key>/` folders are removed once a newer one is
   installed, unless this process uses them (CEF cannot unload).

Retries: backoff 5 s, 15 s, 60 s, 5 min, then every 30 min while the app runs.
Offline: the installer waits for `NWPathMonitor` to report a usable path, it
never polls. Low Data Mode and expensive (hotspot) paths: the background
prefetch waits; a download the person asked for (a Chromium tab, Retry) runs.

### 6.4 Which runtime the app uses

At launch `ChromiumRuntimeStore.select(pin:)` decides:
- Chromium embedded in the app (dev builds, CI, old nightlies): use it. The
  pin is ignored. Nothing changes for these builds.
- `<key>/` installed for the pinned key: use it.
- Else an installed pack with the same `shim_abi` and team: use it now, and
  download the pinned one in the background (it takes over at the next
  launch). After a Sparkle update that bumped CEF, Chromium keeps working
  with the previous engine until the new one is in.
- Else no Chromium yet: `CEFUnavailableReason.downloading(fraction)` or
  `.downloadFailed(message)`.

`CEFEngine` reads its layout from a `CEFRuntimeSource` the app updates, not a
`let` fixed at init: once the install finishes, the next Chromium tab starts
Chromium in this process. No relaunch.

### 6.5 What the person sees

- New tabs with the default engine (Chromium) open in WebKit while the engine
  is missing. The first such tab shows the existing one-time notice, now
  "Chromium is downloading, so this tab uses WebKit. New tabs use Chromium
  when it’s ready."
- When the install finishes, new tabs use Chromium. (A "Chromium is ready"
  notice is not built yet.)
- A tab that explicitly asks for Chromium ("Open in Chromium", `--engine
  chromium`) is refused, as today, with "Chromium is downloading (42%). Try
  again when it’s ready." Every check that finds the download pending (a
  new tab, the palette, the CLI) starts the download at user priority.
- Failure: "Chromium couldn’t download yet, so this tab uses WebKit. cmux will
  try again." The reason (offline, checksum, signature, disk full) is in
  `debug.cef`.
- `debug.cef` reports `runtime`: `{origin: bundled|installed|compatible|downloading|none,
  pinned_key, install, fraction, frameworks, error}`.

### 6.6 Release flow

- `embed-cef.sh` does not change: every build still embeds Chromium, so dev,
  CI and tests keep the engine.
- `scripts/cmux-next/cef-runtime-pack.sh split <app> <out dir> --base-url URL`
  runs inside `sign-cmux-bundle.sh` after `sign-cef.sh` and before the outer
  app is signed, when `CMUX_NEXT_CEF_ON_DEMAND=1`. It moves the signed engine
  into the runtime folder, writes the pin into the app, and writes the pack (or, when
  the key is already published, deletes the engine and reuses the published
  pin).
- `scripts/cmux-next/publish-cef-runtime.sh <out dir>` uploads the pack and its
  pin write-once, then downloads it again and checks the sha256. It runs in the
  publish job before the appcast upload.
- The nightly turns this on with the repository variable
  `CMUX_NEXT_CEF_ON_DEMAND=1`. It is off until one signed nightly is checked by
  hand (download, verify, Chromium tab, Widevine, PDF, DevTools, an
  extension); that check is not automated yet.
- `bundle-size-budget.json` gets the on-demand variant: no CEF in the app,
  app cap −363 MB, DMG cap −103 MB, plus a cap on the pack itself.

### 6.7 Risks and what stays open

- Sandbox: a Chromium start from a folder outside the app needs the
  `cmux_runtime_outside_bundle` CEF patch (6.1). The pin bump to a CEF
  artifact with the patch belongs to the browser lane; until then the nightly
  flag stays off.
- Notarization: the pack is not notarized. It is never quarantined (the app
  downloads it, not a browser), so Gatekeeper does not assess it; its pin is
  inside the notarized app. Notarizing the pack is a later hardening.
- First Chromium tab on a slow link waits for about 100 MB. WebKit covers the
  gap; the prefetch starts 20 s after launch to make that rare.
- Disk: two engines can be on disk for one launch after an update.
