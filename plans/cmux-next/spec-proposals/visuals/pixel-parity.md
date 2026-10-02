# Pixel parity

The macOS app (feat-cmux-next, Swift/AppKit) is the reference. Every port must match its tokens and states pixel for pixel at the same theme, density, scale and window size:

- GPUI client: manaflow-ai/cmux2 and manaflow-ai/cmux2-gpui (lane cmux2-gpui).
- Chromium client: manaflow-ai/cmux-browser (lane cmux-browser).
- Any web/React surface that draws cmux chrome (the agent pane already shares its CSS with the macOS app).

## Rules for ports

1. Import [design-tokens.json](design-tokens.json). Never retype a number. Colors are formulas: port `ThemeTokens.derive` and test it against [tools/derive_theme_tokens.py](tools/derive_theme_tokens.py) for the five reference themes (exact hex, alpha to 1/255).
2. Implement every state in the component pages (default, hover, pressed, selected, keyboard focus, disabled, dragging, unfocused pane, unfocused window, light, dark) and every visual setting (density, borders, focusIndicator, tabBarBackground, focusRing.contrast, inactiveTabStyle, section look, statusIndicator).
3. Same geometry: points map 1:1 to logical pixels; snap pill offsets and hairlines to device pixels the same way (`PaneChromeMetrics.snap/snapDown`, hairline = 1 device pixel).
4. Same motion: springs with response/dampingFraction (convert with stiffness = (2π/response)², damping = 2ζ·2π/response), fades easeOut with the listed durations, Reduce Motion behavior.
5. Fonts: SF Pro / SF Mono on macOS. On Linux and Windows use the platform system UI font at the same point size and record the substitution in the port's parity report; the diff budget below covers glyph rasterization, not size or weight.
6. Materials: Liquid Glass where the platform has a real equivalent; otherwise the documented opaque fallback (`mix(window, textPrimary, 0.14)` plus a separator border), never an invented blur.
7. No blue accent, no platform focus rings, no system selection colors anywhere.

## Screenshot-diff harness (plan)

Goal: one scene, one script, three renderers, a pixel diff per state, run in CI.

1. **Scene fixture.** A JSON scene (`scene.json`) every client can load through the daemon (cmux-tui, protocol/2): window 1100×720 pt, sidebar with 4 workspaces (one selected, one unread badge, one long title), workspace 1 with two panes (left: 2 tabs, right: 1 tab, right focused), fixed terminal contents from a recorded PTY transcript, fixed clock and fonts. The macOS scene in this proposal was built with the CLI commands in [tools/capture.sh](tools/capture.sh) (new-workspace, new-surface, new-split, rename-tab, notify, send).
2. **State script.** A list of steps `{id, settings, theme, appearance, action, crop}` where action is `hover x y`, `press x y`, `key ...`, `tunable k v`, `cmux.json patch`. The macOS driver is `debug.mouse action:hover`, `debug.tunables set`, `debug.appearance`, `reload-config` with `CMUX_NEXT_CONFIG_FILE` and `CMUX_NEXT_GHOSTTY_CONFIG` pointing at scratch files (no user config touched). Each port implements the same verbs on its own debug socket.
3. **Capture.** macOS: `screencapture -o -l <CGWindowID>` of the tagged app window launched with `open -n -g` (never brought to front, never on the user's active window), cropped in points×2 by [tools/shot.py](tools/shot.py). GPUI: render offscreen to an image at scale 2. Chromium: headless or offscreen compositor readback at device scale 2.
4. **Compare.** Per state crop: (a) exact match of sampled token pixels (fill centers, text color in glyph interiors, ring and hairline pixels) against the resolved token; (b) perceptual diff (e.g. pixelmatch threshold 0.1) with a budget of 0.5% of pixels for glyph antialiasing and 0 for geometry (bounding boxes of pills, rings, badges must match to the device pixel). Output a side-by-side HTML report per port.
5. **Reference set.** The PNGs in [images/](images/) are the first reference set (Apple System Colors dark and light, compact, scale 2, cmux `1824883286a`). Regenerate with `tools/capture.sh dark|light` after visual changes on feat-cmux-next, and fail port CI when the reference changes without a matching port update.
6. **Coverage report.** Every state row in the component pages gets a state id; the harness reports which states each port renders, matches, or lacks.

Open work for the harness: drive pressed states (needs a debug verb that sets pressed without AppKit's tracking loop), hover cards (a debug verb that opens a card for a target id), drag and drop overlays (`debug.drop_highlight`), status indicator states (a debug verb that sets a row or tab state), and palette row hover (`debug.mouse` for panels).
