# Browser Wayland SIGTRAP during EGL teardown (#18578)

The Linux cmux Browser nightly exits with `SIGTRAP` about 15 seconds after
launch on Arch Linux under Hyprland/Wayland. The fix belongs in the Chromium
runtime carried by `cmux-browser`, not in the macOS cmux host. This repository
does not contain the Linux Chromium or VA-API implementation.

## Incident evidence

- Reported browser version: `151.0.7922.64`.
- Reporter system: Arch Linux, kernel `6.19.14-arch1-1`, Hyprland/Wayland,
  `WAYLAND_DISPLAY=wayland-1`.
- Browser process: PID `7495`; VA-API helper: PID `7556`.
- The VA-API helper logs `vaInitialize failed: unknown libva error`.
- The browser then emits Chromium's `[DanglingPtr]` report and terminates with
  `SIGTRAP`.
- The exact nightly artifact is recorded in
  [`out/perf-incident-18578/issue.json`](../../out/perf-incident-18578/issue.json).
  The downloaded archive SHA-256 is
  `657efc619c3606e17b415b49ded1d46f8c0f0fb8b1e4dbb3b459483e839e013a`.
  The unpacked `chrome` ELF has Build ID
  `fb6c9c717a8041795a8bf391f63fa3847c947de9`.
- The browser-fork registry was at `7c0a0cf9a8ef150cea9ae1d8da8a37e6d4411ae8`
  and pins Chromium `151.0.7922.34`. The registry checkout is intentionally a
  source-less overlay; it cannot directly patch Chromium's `ui/gl` sources.

The reported stack is stripped, but the exact release binary was disassembled
at each reported offset. Around `chrome+0xe779720`, the destructor-like
function:

1. calls `eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
   EGL_NO_CONTEXT)`;
2. destroys the EGL surface and context;
3. calls `dlclose(this + 0x30)`;
4. clears the same field at `this + 0x30`.

The reported `chrome+0xe77978e` frame is the `dlclose` call and
`chrome+0xe7797f8` is the following field clear. `chrome+0xe779840` calls this
destructor and deletes a `0x48`-byte object. This ordering explains the
`[DanglingPtr]`: the dynamic-library handle is released after `dlclose()` has
already freed the loader-owned memory. The VA-API error is a plausible trigger
for GPU fallback cleanup, but it is not the failing stack; the failing stack is
EGL/GL teardown in the browser process.

Chromium's branch-7922 `ui/gl/gl_implementation.cc` is the relevant ownership
boundary: `AddGLNativeLibrary()` records native GL libraries and
`UnloadGLNativeLibraries()` unloads them during fallback. The Linux path is
deliberately conditional because unloading a live GL library is unsafe. The
fix therefore needs to be made at the Chromium/ANGLE native-EGL loader and
fallback lifetime boundary, with the pointer cleared before unloading (or the
library kept loaded on this failure path). A workaround in cmux's macOS host
would not reach this code. The source reference is
[`gl_implementation.cc`](https://chromium.googlesource.com/chromium/src/+/refs/branch-heads/7922/ui/gl/gl_implementation.cc#184).

## Concrete browser-fork next step

On the `cmux-browser` Chromium patch branch:

1. Rebuild the exact `151.0.7922.34` fork revision with symbols, map
   `chrome+0xe779720` to the owning EGL loader destructor, and confirm whether
   the `this + 0x30` field is the native-library handle/raw pointer.
2. Fix that owner so the raw pointer is cleared before `dlclose()` (or avoid
   `dlclose()` during the Linux GPU fallback teardown). Do not add a
   GPU-vendor workaround without the reporter's PCI identity.
3. Add a Linux regression smoke that keeps Wayland variables, exercises the
   VA-API initialization-failure/fallback path, and asserts that the browser
   remains alive after startup. The current
   `scripts/smoke-release-linux-browser.py` and
   `scripts/release-build-prove-linux-runtime.sh` explicitly force X11, while
   `.github/workflows/release-linux-smoke.yml` uses `--disable-gpu`; none of
   these paths covers this incident.
4. Run the same smoke before and after the patch, recording the exact browser
   SHA/Build ID and exit status. A fix is proven only when the repro no longer
   emits `[DanglingPtr]`/`SIGTRAP` on the same workload.

The reporter should provide these inputs before a hardware-specific workaround
is considered:

```sh
lspci -nnk | grep -A3 -E 'VGA|3D|Display'
vainfo --display drm --device /dev/dri/renderD128
sha256sum cmux-browser-nightly/chrome
```

The saved evidence bundle is under `out/perf-incident-18578/`. The local host
cannot execute the Linux binary, so no claim of a runtime fix is made here.
