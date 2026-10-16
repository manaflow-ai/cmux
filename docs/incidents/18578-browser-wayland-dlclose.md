# Browser Wayland SIGTRAP during EGL teardown (#18578)

The Linux cmux Browser nightly exits with `SIGTRAP` about 15 seconds after
launch on Arch Linux under Hyprland/Wayland. The failing owner is the
Linux-specific OpenGL adapter in the `cmux-browser` overlay, not the macOS
cmux host and not Chromium's generic ANGLE loader. The affected nightly was
built before the browser-fork fix; a newer nightly must be used to deliver it
to users.

## Incident evidence

- Reported browser version: `151.0.7922.64`.
- Reporter system: Arch Linux, kernel `6.19.14-arch1-1`, Hyprland/Wayland,
  `WAYLAND_DISPLAY=wayland-1`.
- Browser process: PID `7495`; VA-API helper: PID `7556`.
- The VA-API helper logs `vaInitialize failed: unknown libva error`.
- The browser then emits Chromium's `[DanglingPtr]` report and terminates with
  `SIGTRAP`.
- The exact nightly artifact was downloaded while investigating the public
  [issue report](https://github.com/manaflow-ai/cmux/issues/18578). The local
  provenance copy is `out/perf-incident-18578/issue.json` and is intentionally
  not part of this documentation commit. The downloaded archive SHA-256 is
  `657efc619c3606e17b415b49ded1d46f8c0f0fb8b1e4dbb3b459483e839e013a`.
  The unpacked `chrome` ELF has Build ID
  `fb6c9c717a8041795a8bf391f63fa3847c947de9`.
- The browser-fork source is an overlay checkout at
  `7c0a0cf9a8ef150cea9ae1d8da8a37e6d4411ae8` and pins Chromium
  `151.0.7922.34`. The affected release was built from browser-fork commit
  `dd7984e7ea68ee42768feebe3691b7b7ffdca6e6`, which predates the fix below.

The reported stack is stripped, but the exact release binary was disassembled
at each reported offset. Around `chrome+0xe779720`, the
`LinuxOpenGLHost` destructor in
`overlay/chrome/browser/cmux_term/cmux_ghostty_opengl_host.cc`:

1. calls `eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
   EGL_NO_CONTEXT)`;
2. destroys the EGL surface and context;
3. calls `dlclose(this + 0x30)`;
4. clears the same field at `this + 0x30`.

The reported `chrome+0xe77978e` frame is the `dlclose` call and
`chrome+0xe7797f8` is the following field clear. `chrome+0xe779840` calls this
destructor and deletes a `0x48`-byte object. This ordering explains the
`[DanglingPtr]`: `lib_gl_` is a Chromium `raw_ptr<void>` that still contains the
loader handle when `dlclose()` releases the loader-owned allocation. The VA-API
error is a plausible trigger for GPU fallback cleanup, but it is not the
failing stack; the failing stack is EGL/GL teardown in the browser process.

## Fix and release status

The browser fork already contains the direct fix in
`9825e8206266f0979dd4a33519362a90a210afa7` (`fix Linux OpenGL host teardown`):

```cpp
void* lib_gl = lib_gl_;
lib_gl_ = nullptr;
if (lib_gl) {
  dlclose(lib_gl);
}
```

That commit also keeps the process-global EGL display alive instead of calling
`eglTerminate()` from one host's destructor. It is an ancestor of the current
browser-fork `main`, so no duplicate runtime patch is needed in cmux. The
affected `151.0.7922.64` artifact is stale; it cannot contain this fix.

A later nightly whose release metadata proves it was built from a fixed
source is `151.0.7922.91`, source commit
`31e90278ed8557bb1a131e5fb5236681ab4af4ae`, from the
[Linux nightly run](https://github.com/manaflow-ai/cmux-browser/actions/runs/31374570260).
Its release metadata records the source SHA and the corresponding source
archive. The source commit contains `9825e820` (`git merge-base --is-ancestor`
passes). This establishes that the packaged source includes the fix; a runtime
closeout still requires the reporter to repeat the Wayland/VA-API workload on
that newer nightly and confirm no `[DanglingPtr]`/`SIGTRAP`.

The practical next step is therefore to have the reporter upgrade to
`151.0.7922.91` (or a later nightly), repeat the original workload, and attach
the exit status and browser SHA/Build ID. If the crash persists on a fixed
source build, collect the requested GPU details before considering a
vendor-specific workaround.

The reporter should provide these inputs before a hardware-specific workaround
is considered:

```sh
lspci -nnk | grep -A3 -E 'VGA|3D|Display'
vainfo --display drm --device /dev/dri/renderD128
sha256sum cmux-browser-nightly/chrome
```

The saved evidence bundle is under `out/perf-incident-18578/`. The local host
cannot execute the Linux binary, so no claim of a runtime fix is made here.
