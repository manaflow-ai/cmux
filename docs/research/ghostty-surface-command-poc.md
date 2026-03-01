# PoC: Ghostty surfaceConfig.command Field

## Status: UNTESTED — Task 5 in the implementation plan

## What We Know

The `ghostty_surface_config_s` struct (`ghostty.h:440-453`) has a `command` field:

```c
typedef struct {
  // ...
  const char* command;          // line 447
  bool wait_after_command;      // line 451
  // ...
} ghostty_surface_config_s;
```

**cmux never sets this field.** All terminal surfaces launch the user's default shell. The field is initialized to NULL by `ghostty_surface_config_new()`.

Ghostty's upstream macOS app (not cmux) uses this field in its GTK app runtime. The embedded runtime (which cmux uses) should support it, but this is unverified.

## PoC Steps

1. In `Sources/GhosttyTerminalView.swift:1861` (inside `createSurface(for:)`), add before the `ghostty_surface_new()` call:

```swift
// PoC: test surfaceConfig.command field
surfaceConfig.command = strdup("/bin/echo hello world from ghostty command field")
```

2. Build and launch:
```bash
./scripts/reload.sh --tag crux-poc
```

3. Open a new workspace (Cmd+N). If the terminal shows:
   - `hello world from ghostty command field` → **PASS** — the field works
   - A shell prompt (`$ ` or `% `) → **FAIL** — embedded runtime ignores the field

4. If PASS, also test `wait_after_command`:
```swift
surfaceConfig.command = strdup("/bin/echo hello world")
surfaceConfig.wait_after_command = true
```
The terminal should show the output and wait (not close immediately).

5. **Revert all changes** after the PoC regardless of outcome.

## If FAIL

The fallback is `Foundation.Process` with `Pipe` for stdout/stderr capture. This loses:
- Live terminal rendering (ANSI, colors, progress bars)
- Interactive terminal (can't type into running task)
- Shell integration hooks
- Scrollback

But gains:
- Proven reliability (cmux uses Process in PortScanner already)
- No Ghostty dependency for scheduler execution

**User decides the fallback approach** — do not proceed without confirmation.

## Memory Safety Note

The PoC uses `strdup()` which allocates on the heap. This is fine for testing but leaks memory. The production code uses `withCString {}` scoping:

```swift
task.command.withCString { cmd in
    config.command = cmd
    // ... create surface within this scope
}
```

The `withCString` pattern ensures the C string is valid for the duration of the closure and freed afterward.
