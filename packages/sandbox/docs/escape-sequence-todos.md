# Escape Sequence Support TODOs

This document tracks OSC and CSI escape sequences to implement for better terminal emulator compatibility (tmux/zellij parity).

## Currently Supported

See `src/mux/terminal.rs` for the current implementation. Key supported sequences:
- OSC 0, 2 (window title)
- CSI cursor movement, erase, scroll, SGR colors
- DEC private modes: cursor visibility, alternate screen, mouse tracking, bracketed paste

---

## To Implement

### Easy (1-2 hours each)

- [x] **CSI c** - Primary Device Attributes (DA1)
  - Apps send `CSI c` or `CSI 0 c` to query terminal type
  - Respond with `CSI ? 62 ; 1 ; 2 ; 4 c` (VT220 with various capabilities)
  - Many CLI tools use this to detect terminal features

- [x] **CSI > c** - Secondary Device Attributes (DA2)
  - Apps send `CSI > c` to get terminal version info
  - Respond with `CSI > 41 ; <version> ; 0 c` (identify as screen/tmux-like)

- [x] **CSI ? 12 h/l** - Cursor Blink
  - `CSI ? 12 h` = enable cursor blink
  - `CSI ? 12 l` = disable cursor blink
  - Store in terminal state, expose to renderer

- [x] **CSI ! p** - Soft Terminal Reset (DECSTR)
  - Reset modes to defaults without clearing screen
  - Resets: insert mode, origin mode, auto-wrap, cursor visibility, SGR, scroll region

- [x] **OSC 10/11** - Query/Set Default Colors
  - OSC 10 = foreground color
  - OSC 11 = background color
  - Query: `OSC 10 ? ST` → respond with current color
  - Set: `OSC 10 ; <color> ST`
  - OSC 110/111 = reset to terminal defaults

- [ ] **OSC 112** - Reset Cursor Color
  - Simple: reset cursor color to default
  - `OSC 112 ST`

- [ ] **CSI ? 1004 h/l** - Focus Reporting
  - `CSI ? 1004 h` = enable focus events
  - `CSI ? 1004 l` = disable focus events
  - When enabled, send `CSI I` on focus in, `CSI O` on focus out
  - Used by vim/neovim to detect when terminal gains/loses focus

- [ ] **OSC 7** - Current Working Directory
  - Format: `OSC 7 ; file://hostname/path ST`
  - Shells emit this after each command
  - Store in terminal state for UI display / tab titles

- [ ] **CSI ? 1034 h/l** - Meta Sends Escape
  - Controls whether Alt+key sends ESC+key or sets high bit
  - Most terminals default to ESC prefix mode

### Medium (2-4 hours each)

- [ ] **OSC 52** - Clipboard Access
  - Format: `OSC 52 ; <target> ; <base64-data> ST`
  - Target: `c` = clipboard, `p` = primary selection
  - Read: `OSC 52 ; c ; ? ST` → respond with base64 clipboard contents
  - Write: `OSC 52 ; c ; <base64> ST` → set clipboard
  - Security consideration: may want to prompt user or limit to write-only

- [ ] **OSC 4** - Color Palette Query/Set
  - Query: `OSC 4 ; <index> ; ? ST` → respond with RGB
  - Set: `OSC 4 ; <index> ; <color> ST`
  - Index 0-255 for 256-color palette

- [ ] **CSI ? 2026 h/l** - Synchronized Output
  - `CSI ? 2026 h` = begin synchronized update (buffer output)
  - `CSI ? 2026 l` = end synchronized update (flush to screen)
  - Reduces flicker during rapid screen updates
  - Buffer writes between begin/end, render atomically on end

- [ ] **OSC 8** - Hyperlinks
  - Format: `OSC 8 ; params ; uri ST text OSC 8 ; ; ST`
  - Store hyperlink state with cells
  - Renderer needs to make text clickable
  - params can include `id=xxx` for grouping multi-line links

- [ ] **CSI t** - Window Manipulation (subset)
  - Many subcommands, implement common ones:
  - `CSI 14 t` - report window size in pixels
  - `CSI 18 t` - report terminal size in chars
  - `CSI 22 ; 0 t` / `CSI 23 ; 0 t` - push/pop title

- [ ] **OSC 133** - Shell Integration / Prompt Markers
  - `OSC 133 ; A ST` - prompt start
  - `OSC 133 ; B ST` - prompt end (command start)
  - `OSC 133 ; C ST` - command end (output start)
  - `OSC 133 ; D ; <exitcode> ST` - command finished
  - Enables: click to scroll to prompt, re-run commands, semantic regions

### Hard (4+ hours each)

- [ ] **CSI ? 1007 h/l** - Alternate Scroll Mode
  - When in alternate screen and this is enabled:
  - Scroll wheel sends arrow keys instead of scrolling
  - Useful for less/man/vim scroll behavior

- [ ] **Kitty Keyboard Protocol** - Extended Key Reporting
  - `CSI > <flags> u` to enable
  - Reports key press/release, modifiers, key codes
  - Complex: multiple modes, disambiguation, legacy fallback
  - Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/

- [ ] **OSC 1337** - iTerm2 Inline Images
  - Format: `OSC 1337 ; File=<args> : <base64-data> ST`
  - Display images inline in terminal
  - Need image decoding, cell placement, aspect ratio handling

- [ ] **Sixel Graphics**
  - DCS sequence for bitmap graphics
  - Legacy but still used (e.g., `libsixel`, `img2sixel`)
  - Complex parsing and rendering

---

## Not Planning to Support

- OSC 9 (Growl notifications) - deprecated
- DECRQSS (request selection) - rarely used
- DECSCA (protected area) - rarely used
- Most VT52 compatibility sequences

---

## Testing

For each implemented sequence, add tests in `src/mux/terminal.rs`:
- Parse correctly
- State changes as expected
- Output/response is correct (for queries)
- Edge cases (malformed input, boundary conditions)

Reference terminals for behavior verification:
- xterm (canonical reference)
- kitty (modern features)
- alacritty (GPU-accelerated reference)
- foot (Wayland reference)
