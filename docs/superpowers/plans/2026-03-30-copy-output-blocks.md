# Copy Output Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users copy individual command output blocks (or all blocks) with a single click via a floating overlay button, using Ghostty's existing OSC 133 semantic zone data.

**Architecture:** Add C API functions in the Ghostty submodule that query output block boundaries using the existing `PromptIterator` and `highlightSemanticContent()`. Bridge these to Swift via a lightweight `OutputBlockProvider`. Render a HUD-style overlay button (matching existing badge pattern) on hover. Expose programmatic access through socket commands.

**Tech Stack:** Zig (Ghostty C API), Swift/AppKit (overlay UI), SwiftUI (none — pure AppKit overlay for layering contract compliance)

**Branch:** `feature/copy-output-blocks` (based on `feature/project-groups`)

**Ghostty submodule workflow:** All Zig changes go in the `ghostty` submodule → push to `manaflow-ai/ghostty` fork → update submodule pointer in parent.

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `ghostty/src/terminal/PageList.zig` | Add `collectOutputBlocks()` helper that returns block boundaries |
| Modify | `ghostty/src/apprt/embedded.zig` | Export C API functions for output block queries |
| Modify | `ghostty.h` | Declare new C API functions |
| Create | `Sources/OutputBlockProvider.swift` | Swift bridge wrapping C API calls |
| Create | `Sources/CopyBlockOverlay.swift` | AppKit overlay view (HUD pill with copy button) |
| Modify | `Sources/GhosttyTerminalView.swift` | Hover detection, overlay lifecycle, z-ordering |
| Modify | `Sources/TerminalController.swift` | Socket commands for programmatic access |

---

### Task 1: Add Output Block Collection Helper to PageList (Zig)

**Files:**
- Modify: `ghostty/src/terminal/PageList.zig:4241+`

This task adds a method to PageList that collects all output block boundaries in one pass. It builds on the existing `PromptIterator` and `highlightSemanticContent()`.

- [ ] **Step 1: Add OutputBlock result struct and collectOutputBlocks method**

In `ghostty/src/terminal/PageList.zig`, add after the `highlightSemanticContent` function (after line ~4371):

```zig
/// Represents the boundaries of a single command output block.
pub const OutputBlock = struct {
    /// The first cell of the output content.
    start: Pin,
    /// The last cell of the output content.
    end: Pin,
};

/// Collect all output blocks in the page list by iterating through prompt
/// boundaries and extracting the output region between each pair.
/// Returns a slice allocated with the given allocator. Caller owns the memory.
pub fn collectOutputBlocks(
    self: *const PageList,
    alloc: Allocator,
) ![]OutputBlock {
    var blocks = std.ArrayList(OutputBlock).init(alloc);
    errdefer blocks.deinit();

    // Get the top-left of the entire screen (start of scrollback).
    const tl = self.getTopLeft(.screen) orelse return blocks.toOwnedSlice();

    // Iterate through all prompts from top to bottom.
    var it = tl.promptIterator(.right_down, null);
    while (it.next()) |prompt_pin| {
        // For each prompt, find the output region.
        if (self.highlightSemanticContent(prompt_pin, .output)) |highlight| {
            try blocks.append(.{
                .start = highlight.start,
                .end = highlight.end,
            });
        }
    }

    return blocks.toOwnedSlice();
}

/// Find which output block (by index) contains the given pin.
/// Returns null if the pin is not within any output block.
pub fn outputBlockIndexAtPin(
    self: *const PageList,
    at: Pin,
    blocks: []const OutputBlock,
) ?usize {
    for (blocks, 0..) |block, i| {
        // Check if 'at' is between block.start and block.end.
        if (self.comparePin(block.start, at) != .gt and
            self.comparePin(at, block.end) != .gt)
        {
            return i;
        }
    }
    return null;
}
```

- [ ] **Step 2: Add Zig tests for collectOutputBlocks**

Add test cases in the same file's test block section:

```zig
test "PageList: collectOutputBlocks returns empty for no prompts" {
    const alloc = testing.allocator;
    var s: PageList = try PageList.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer s.deinit();

    const blocks = try s.collectOutputBlocks(alloc);
    defer alloc.free(blocks);
    try testing.expectEqual(@as(usize, 0), blocks.len);
}

test "PageList: collectOutputBlocks finds single output block" {
    const alloc = testing.allocator;
    var s: PageList = try PageList.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer s.deinit();

    // Set up a prompt row followed by output rows.
    // Row 0: prompt
    const tl = s.getTopLeft(.screen).?;
    {
        const rac = tl.rowAndCell();
        rac.row.semantic_prompt = .prompt;
        // Write a prompt cell
        rac.cell.* = .{ .semantic_content = .prompt };
        rac.cell.content_tag = .codepoint;
        rac.cell.content = .{ .codepoint = '$' };
    }
    // Row 1: input
    if (tl.down(1)) |p| {
        const rac = p.rowAndCell();
        rac.cell.* = .{ .semantic_content = .input };
        rac.cell.content_tag = .codepoint;
        rac.cell.content = .{ .codepoint = 'l' };
    }
    // Row 2: output
    if (tl.down(2)) |p| {
        const rac = p.rowAndCell();
        rac.cell.* = .{ .semantic_content = .output };
        rac.cell.content_tag = .codepoint;
        rac.cell.content = .{ .codepoint = 'f' };
    }

    // Second prompt at row 4 to close the block
    if (tl.down(4)) |p| {
        const rac = p.rowAndCell();
        rac.row.semantic_prompt = .prompt;
        rac.cell.* = .{ .semantic_content = .prompt };
        rac.cell.content_tag = .codepoint;
        rac.cell.content = .{ .codepoint = '$' };
    }

    const blocks = try s.collectOutputBlocks(alloc);
    defer alloc.free(blocks);
    try testing.expectEqual(@as(usize, 1), blocks.len);
}
```

- [ ] **Step 3: Run Zig tests to verify**

```bash
cd ghostty && zig build test -Dtest-filter="PageList: collectOutputBlocks" 2>&1 | head -20
```

Expected: PASS

- [ ] **Step 4: Commit in ghostty submodule**

```bash
cd ghostty
git add src/terminal/PageList.zig
git commit -m "feat: add collectOutputBlocks and outputBlockIndexAtPin to PageList

Collects output block boundaries using existing PromptIterator and
highlightSemanticContent. Returns Pin-based start/end pairs for each
command output region in the scrollback."
```

---

### Task 2: Export C API Functions (Zig + C Header)

**Files:**
- Modify: `ghostty/src/apprt/embedded.zig:1723+`
- Modify: `ghostty.h:1123+`

Expose the output block queries through the C embedding API that cmux uses.

- [ ] **Step 1: Add C-compatible types to embedded.zig**

In `ghostty/src/apprt/embedded.zig`, add a new struct and the export functions after `ghostty_surface_free_text` (line ~1727):

```zig
    /// Opaque handle for a cached set of output blocks.
    /// Must be freed with ghostty_surface_free_output_blocks.
    const OutputBlocks = struct {
        blocks: []const terminal.PageList.OutputBlock,
        alloc: Allocator,

        pub fn deinit(self: *OutputBlocks) void {
            self.alloc.free(self.blocks);
            self.* = undefined;
        }
    };

    /// Collect all output blocks in the terminal. Returns an opaque handle.
    /// The caller must free the result with ghostty_surface_free_output_blocks.
    /// Returns the count of blocks found. If count is 0, handle is not set.
    export fn ghostty_surface_collect_output_blocks(
        surface: *Surface,
        handle: *?*OutputBlocks,
    ) u32 {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = &core_surface.renderer_state.terminal.screens.active;
        const blocks = screen.pages.collectOutputBlocks(global.alloc) catch |err| {
            log.warn("error collecting output blocks err={}", .{err});
            handle.* = null;
            return 0;
        };

        if (blocks.len == 0) {
            global.alloc.free(blocks);
            handle.* = null;
            return 0;
        }

        const ob = global.alloc.create(OutputBlocks) catch |err| {
            log.warn("error allocating output blocks handle err={}", .{err});
            global.alloc.free(blocks);
            handle.* = null;
            return 0;
        };
        ob.* = .{ .blocks = blocks, .alloc = global.alloc };
        handle.* = ob;
        return @intCast(blocks.len);
    }

    /// Read the text of output block at the given index from a collected set.
    /// The handle must have been obtained from ghostty_surface_collect_output_blocks.
    export fn ghostty_surface_read_output_block(
        surface: *Surface,
        ob_handle: *OutputBlocks,
        index: u32,
        result: *Text,
    ) bool {
        if (index >= ob_handle.blocks.len) return false;

        const block = ob_handle.blocks[index];
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const sel = terminal.Selection.init(
            block.start,
            block.end,
            false,
        );

        return readTextLocked(surface, sel, result);
    }

    /// Given a viewport row, find which output block index it belongs to.
    /// Returns UINT32_MAX if the row is not within any output block.
    export fn ghostty_surface_output_block_at_viewport_row(
        surface: *Surface,
        ob_handle: *OutputBlocks,
        viewport_row: u32,
    ) u32 {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = &core_surface.renderer_state.terminal.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{
            .x = 0,
            .y = viewport_row,
        } }) orelse return std.math.maxInt(u32);

        return if (screen.pages.outputBlockIndexAtPin(pin, ob_handle.blocks)) |idx|
            @intCast(idx)
        else
            std.math.maxInt(u32);
    }

    /// Get the viewport row range for an output block.
    /// Returns false if the block is not visible in the viewport.
    export fn ghostty_surface_output_block_viewport_rows(
        surface: *Surface,
        ob_handle: *OutputBlocks,
        index: u32,
        top_row: *u32,
        bottom_row: *u32,
    ) bool {
        if (index >= ob_handle.blocks.len) return false;

        const block = ob_handle.blocks[index];
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = &core_surface.renderer_state.terminal.screens.active;

        // Convert pins to viewport coordinates.
        const start_vp = screen.pages.pointFromPin(.viewport, block.start) orelse return false;
        const end_vp = screen.pages.pointFromPin(.viewport, block.end) orelse return false;

        top_row.* = start_vp.viewport.y;
        bottom_row.* = end_vp.viewport.y;
        return true;
    }

    /// Free an output blocks handle.
    export fn ghostty_surface_free_output_blocks(handle: *?*OutputBlocks) void {
        if (handle.*) |ob| {
            ob.deinit();
            global.alloc.destroy(ob);
            handle.* = null;
        }
    }
```

- [ ] **Step 2: Commit in ghostty submodule and push to fork**

```bash
cd ghostty
git add src/apprt/embedded.zig
git commit -m "feat: add output block C API for cmux copy-block feature

Exports: ghostty_surface_collect_output_blocks,
ghostty_surface_read_output_block,
ghostty_surface_output_block_at_viewport_row,
ghostty_surface_output_block_viewport_rows,
ghostty_surface_free_output_blocks"
git push manaflow HEAD
```

- [ ] **Step 3: Add C declarations to ghostty.h**

In `ghostty.h`, after the `ghostty_surface_free_text` declaration (line ~1123), add:

```c
// Output block API — query and read semantic output blocks (OSC 133)
typedef struct ghostty_output_blocks_s ghostty_output_blocks_s;
typedef ghostty_output_blocks_s* ghostty_output_blocks_t;

uint32_t ghostty_surface_collect_output_blocks(ghostty_surface_t,
                                                ghostty_output_blocks_t*);
bool ghostty_surface_read_output_block(ghostty_surface_t,
                                        ghostty_output_blocks_t,
                                        uint32_t index,
                                        ghostty_text_s*);
uint32_t ghostty_surface_output_block_at_viewport_row(ghostty_surface_t,
                                                       ghostty_output_blocks_t,
                                                       uint32_t row);
bool ghostty_surface_output_block_viewport_rows(ghostty_surface_t,
                                                 ghostty_output_blocks_t,
                                                 uint32_t index,
                                                 uint32_t* top_row,
                                                 uint32_t* bottom_row);
void ghostty_surface_free_output_blocks(ghostty_output_blocks_t*);
```

- [ ] **Step 4: Update ghostty submodule pointer and commit**

```bash
cd /Users/znboston/git/cmux
git add ghostty ghostty.h
git commit -m "feat: add output block C API declarations and update ghostty submodule"
```

- [ ] **Step 5: Verify compilation**

```bash
./scripts/reload.sh --tag copy-blocks
```

Expected: Build succeeds (no Swift code uses the new functions yet).

---

### Task 3: Swift OutputBlockProvider Bridge

**Files:**
- Create: `Sources/OutputBlockProvider.swift`

A lightweight class that wraps the C API calls and provides a clean Swift interface.

- [ ] **Step 1: Create OutputBlockProvider.swift**

```swift
import Foundation

/// Provides access to terminal output blocks (semantic zones between shell prompts).
/// Uses Ghostty's OSC 133 data to identify command output regions.
///
/// Usage:
///   let provider = OutputBlockProvider(surface: ghosttySurface)
///   provider.refresh()  // collect blocks from terminal
///   if let text = provider.readBlock(at: 0) { ... }
///   provider.invalidate()  // free when done
///
/// Thread safety: All methods must be called from the main thread.
final class OutputBlockProvider {
    private let surface: ghostty_surface_t
    private var handle: ghostty_output_blocks_t?
    private(set) var blockCount: UInt32 = 0

    init(surface: ghostty_surface_t) {
        self.surface = surface
    }

    deinit {
        invalidate()
    }

    /// Collect output blocks from the terminal. Invalidates any previous collection.
    func refresh() {
        invalidate()
        blockCount = ghostty_surface_collect_output_blocks(surface, &handle)
    }

    /// Free the current block collection.
    func invalidate() {
        if handle != nil {
            ghostty_surface_free_output_blocks(&handle)
            handle = nil
            blockCount = 0
        }
    }

    /// Read the text content of block at the given index.
    /// Index 0 is the oldest block; blockCount-1 is the most recent.
    func readBlock(at index: UInt32) -> String? {
        guard let handle else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_output_block(surface, handle, index, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return nil }
        return String(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: text.text),
            length: text.text_len,
            encoding: .utf8,
            freeWhenDone: false
        )
    }

    /// Read all output blocks concatenated, separated by double newlines.
    func readAllBlocks() -> String? {
        guard blockCount > 0 else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(Int(blockCount))
        for i in 0..<blockCount {
            if let text = readBlock(at: i) {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Find which block index contains the given viewport row.
    /// Returns nil if the row is not within any output block.
    func blockIndex(atViewportRow row: UInt32) -> UInt32? {
        guard let handle else { return nil }
        let idx = ghostty_surface_output_block_at_viewport_row(surface, handle, row)
        return idx == UInt32.max ? nil : idx
    }

    /// Get the viewport row range of a block. Returns nil if the block is
    /// not visible in the current viewport.
    func viewportRows(forBlock index: UInt32) -> (top: UInt32, bottom: UInt32)? {
        guard let handle else { return nil }
        var topRow: UInt32 = 0
        var bottomRow: UInt32 = 0
        guard ghostty_surface_output_block_viewport_rows(
            surface, handle, index, &topRow, &bottomRow
        ) else {
            return nil
        }
        return (topRow, bottomRow)
    }
}
```

- [ ] **Step 2: Add to Xcode project**

Add `Sources/OutputBlockProvider.swift` to the cmux target in the Xcode project.

- [ ] **Step 3: Verify compilation**

```bash
./scripts/reload.sh --tag copy-blocks
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/OutputBlockProvider.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "feat: add OutputBlockProvider Swift bridge for output block C API"
```

---

### Task 4: CopyBlockOverlay AppKit View

**Files:**
- Create: `Sources/CopyBlockOverlay.swift`

A HUD-style pill button that appears over the terminal to let the user copy an output block. Matches the visual style of the existing keyboard copy mode badge.

- [ ] **Step 1: Create CopyBlockOverlay.swift**

```swift
import AppKit

protocol CopyBlockOverlayDelegate: AnyObject {
    func copyBlockOverlayDidRequestCopy(_ overlay: CopyBlockOverlay)
    func copyBlockOverlayDidRequestCopyAll(_ overlay: CopyBlockOverlay)
}

/// A floating HUD-style pill button that appears at the top-right of a hovered
/// output block. Provides "Copy" and "Copy All" actions.
final class CopyBlockOverlay: NSView {
    weak var delegate: CopyBlockOverlayDelegate?

    /// The output block index this overlay is currently showing for.
    var blockIndex: UInt32?

    private let backgroundView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.22
        v.layer?.shadowRadius = 6
        v.layer?.shadowOffset = CGSize(width: 0, height: -1)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let copyButton: NSButton = {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: String(
                localized: "copy.block.button.accessibility",
                defaultValue: "Copy block"
            )
        )
        b.imagePosition = .imageLeading
        b.title = String(localized: "copy.block.button.title", defaultValue: "Copy")
        b.font = .systemFont(ofSize: 11, weight: .medium)
        b.contentTintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let separator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let copyAllButton: NSButton = {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.image = NSImage(
            systemSymbolName: "doc.on.doc.fill",
            accessibilityDescription: String(
                localized: "copy.all.button.accessibility",
                defaultValue: "Copy all blocks"
            )
        )
        b.imagePosition = .imageOnly
        b.contentTintColor = .white.withAlphaComponent(0.7)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.toolTip = String(localized: "copy.all.button.tooltip", defaultValue: "Copy all output")
        return b
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        alphaValue = 0
        wantsLayer = true

        addSubview(backgroundView)
        backgroundView.addSubview(copyButton)
        backgroundView.addSubview(separator)
        backgroundView.addSubview(copyAllButton)

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyAllButton.target = self
        copyAllButton.action = #selector(copyAllClicked)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            copyButton.leadingAnchor.constraint(
                equalTo: backgroundView.leadingAnchor, constant: 8
            ),
            copyButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),

            separator.leadingAnchor.constraint(
                equalTo: copyButton.trailingAnchor, constant: 6
            ),
            separator.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 14),

            copyAllButton.leadingAnchor.constraint(
                equalTo: separator.trailingAnchor, constant: 6
            ),
            copyAllButton.trailingAnchor.constraint(
                equalTo: backgroundView.trailingAnchor, constant: -6
            ),
            copyAllButton.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),

            backgroundView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Show the overlay with a fade-in animation.
    func show(for blockIdx: UInt32) {
        blockIndex = blockIdx
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0.97
        }
    }

    /// Hide the overlay with a fade-out animation.
    func hide() {
        blockIndex = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        }
    }

    /// Flash a brief "Copied!" confirmation.
    func flashCopied() {
        let original = copyButton.title
        copyButton.title = String(localized: "copy.block.copied", defaultValue: "Copied!")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.copyButton.title = original
        }
    }

    // The overlay itself should not intercept mouse events in the terminal.
    // But the buttons inside it should work. hitTest handles this:
    // return nil for the background (passthrough), return the button for clicks on buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === backgroundView {
            return nil // passthrough to terminal
        }
        return hit
    }

    @objc private func copyClicked() {
        delegate?.copyBlockOverlayDidRequestCopy(self)
    }

    @objc private func copyAllClicked() {
        delegate?.copyBlockOverlayDidRequestCopyAll(self)
    }
}
```

- [ ] **Step 2: Add to Xcode project**

Add `Sources/CopyBlockOverlay.swift` to the cmux target.

- [ ] **Step 3: Verify compilation**

```bash
./scripts/reload.sh --tag copy-blocks
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/CopyBlockOverlay.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "feat: add CopyBlockOverlay AppKit view with copy/copy-all buttons"
```

---

### Task 5: Hover Detection and Overlay Integration

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift`

Wire up the overlay into `GhosttySurfaceScrollView`: detect which output block the mouse is hovering over, position the overlay at the top-right of that block, and handle copy actions.

- [ ] **Step 1: Add properties to GhosttySurfaceScrollView**

In `GhosttySurfaceScrollView` (in `Sources/GhosttyTerminalView.swift`), add instance properties alongside the existing overlay properties (near `keyboardCopyModeBadgeContainerView`):

```swift
// MARK: - Copy Block Overlay

/// The floating copy button overlay for output blocks.
private lazy var copyBlockOverlay: CopyBlockOverlay = {
    let overlay = CopyBlockOverlay()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.delegate = self
    return overlay
}()

/// Provider for querying output block boundaries.
private var outputBlockProvider: OutputBlockProvider?

/// The last viewport row the mouse was on, used to avoid redundant lookups.
private var lastHoveredViewportRow: UInt32?

/// The block index currently shown by the overlay.
private var currentOverlayBlockIndex: UInt32?

/// Work item for deferred overlay show (avoids flicker on fast mouse movement).
private var copyBlockOverlayShowWorkItem: DispatchWorkItem?

/// Top constraint for positioning the overlay vertically.
private var copyBlockOverlayTopConstraint: NSLayoutConstraint?
```

- [ ] **Step 2: Initialize and mount the overlay**

In the method where other overlays are added as subviews (the setup/layout method of `GhosttySurfaceScrollView`), add the copy block overlay. Find where `keyboardCopyModeBadgeContainerView` is added and add nearby:

```swift
// Add copy block overlay
addSubview(copyBlockOverlay, positioned: .below, relativeTo: keyboardCopyModeBadgeContainerView)

let topConstraint = copyBlockOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 8)
copyBlockOverlayTopConstraint = topConstraint

NSLayoutConstraint.activate([
    topConstraint,
    copyBlockOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
])
```

- [ ] **Step 3: Initialize OutputBlockProvider when surface is set**

In the method where the Ghostty surface is configured (where `ghostty_surface_mouse_pos` is first called or in the surface setter), add:

```swift
if let surface = self.surface {
    outputBlockProvider = OutputBlockProvider(surface: surface)
}
```

- [ ] **Step 4: Add hover detection in mouseMoved**

In the existing `mouseMoved(with:)` override (line ~6493), add output block detection **after** the existing `ghostty_surface_mouse_pos` call. This keeps the existing path untouched and only adds work on pointer events:

```swift
// Output block hover detection — throttled to row changes only.
updateCopyBlockOverlay(for: event)
```

Then add the implementation method:

```swift
/// Check if the mouse is hovering over an output block and show/hide the overlay.
private func updateCopyBlockOverlay(for event: NSEvent) {
    guard let provider = outputBlockProvider else { return }

    let point = convert(event.locationInWindow, from: nil)
    let cellHeight = cellSize.height
    guard cellHeight > 0 else { return }

    // Convert mouse Y to viewport row. Terminal Y is inverted.
    let terminalY = bounds.height - point.y
    let viewportRow = UInt32(terminalY / cellHeight)

    // Skip if we're on the same row as last check.
    if viewportRow == lastHoveredViewportRow { return }
    lastHoveredViewportRow = viewportRow

    // Refresh blocks (this is relatively cheap — one pass through prompts).
    provider.refresh()

    // Find which block this row belongs to.
    guard let blockIdx = provider.blockIndex(atViewportRow: viewportRow) else {
        hideCopyBlockOverlay()
        return
    }

    // If already showing this block, nothing to do.
    if blockIdx == currentOverlayBlockIndex { return }

    // Show overlay for this block.
    showCopyBlockOverlay(for: blockIdx, provider: provider)
}

private func showCopyBlockOverlay(for blockIdx: UInt32, provider: OutputBlockProvider) {
    // Cancel any pending show.
    copyBlockOverlayShowWorkItem?.cancel()

    // Get the viewport position of the block's top row.
    guard let rows = provider.viewportRows(forBlock: blockIdx) else {
        hideCopyBlockOverlay()
        return
    }

    let cellHeight = cellSize.height
    // Position overlay at the top-right of the block.
    // Terminal coordinates: row 0 is at top of viewport.
    let topY = CGFloat(rows.top) * cellHeight

    let workItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.currentOverlayBlockIndex = blockIdx
        self.copyBlockOverlayTopConstraint?.constant = topY + 4
        self.copyBlockOverlay.show(for: blockIdx)
    }
    copyBlockOverlayShowWorkItem = workItem

    // Slight delay to avoid flicker when moving quickly across blocks.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
}

private func hideCopyBlockOverlay() {
    copyBlockOverlayShowWorkItem?.cancel()
    copyBlockOverlayShowWorkItem = nil

    guard currentOverlayBlockIndex != nil else { return }
    currentOverlayBlockIndex = nil
    copyBlockOverlay.hide()
}
```

- [ ] **Step 5: Hide overlay on mouseExited and scroll**

In the existing `mouseExited(with:)` override, add:

```swift
hideCopyBlockOverlay()
lastHoveredViewportRow = nil
```

Also invalidate the block cache on scroll by adding to the scroll notification handler (or viewport change handler):

```swift
outputBlockProvider?.invalidate()
currentOverlayBlockIndex = nil
```

- [ ] **Step 6: Implement CopyBlockOverlayDelegate**

Add a conformance extension on `GhosttySurfaceScrollView`:

```swift
extension GhosttySurfaceScrollView: CopyBlockOverlayDelegate {
    func copyBlockOverlayDidRequestCopy(_ overlay: CopyBlockOverlay) {
        guard let blockIdx = overlay.blockIndex,
              let provider = outputBlockProvider else { return }

        provider.refresh()
        guard let text = provider.readBlock(at: blockIdx) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overlay.flashCopied()

        #if DEBUG
        dlog("copy.block: copied block \(blockIdx) (\(text.count) chars)")
        #endif
    }

    func copyBlockOverlayDidRequestCopyAll(_ overlay: CopyBlockOverlay) {
        guard let provider = outputBlockProvider else { return }

        provider.refresh()
        guard let text = provider.readAllBlocks() else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overlay.flashCopied()

        #if DEBUG
        dlog("copy.block: copied all \(provider.blockCount) blocks (\(text.count) chars)")
        #endif
    }
}
```

- [ ] **Step 7: Verify compilation and manual test**

```bash
./scripts/reload.sh --tag copy-blocks --launch
```

Expected: Build succeeds. When hovering over terminal output in a shell with OSC 133 (zsh with prompt integration), a copy button should appear. Clicking "Copy" should put that command's output on the clipboard.

- [ ] **Step 8: Commit**

```bash
git add Sources/GhosttyTerminalView.swift
git commit -m "feat: integrate copy block overlay with hover detection

Shows a floating copy button when hovering over command output blocks.
Uses OutputBlockProvider to query Ghostty's OSC 133 semantic zones.
Copy and Copy All actions put text on the system clipboard."
```

---

### Task 6: Socket Commands for Programmatic Access

**Files:**
- Modify: `Sources/TerminalController.swift`

Add socket commands so external tools (cmux CLI, scripts) can query and copy output blocks.

- [ ] **Step 1: Register socket commands**

In the command dispatch table in `TerminalController.swift` (where other `surface.*` commands are registered), add:

```swift
"surface.output_blocks": v2SurfaceOutputBlocks,
"surface.copy_output_block": v2SurfaceCopyOutputBlock,
```

- [ ] **Step 2: Implement surface.output_blocks command**

Add the handler method:

```swift
/// List output blocks with their index and line count.
/// Returns: { "blocks": [{ "index": N, "lines": N }], "count": N }
private func v2SurfaceOutputBlocks(
    _ args: [String: Any],
    reply: @escaping (Any?) -> Void
) {
    let (surface, _) = resolveTerminalSurface(args)
    guard let surface else {
        reply(["error": "no_surface"])
        return
    }

    let provider = OutputBlockProvider(surface: surface)
    provider.refresh()
    defer { provider.invalidate() }

    var blocks: [[String: Any]] = []
    for i in 0..<provider.blockCount {
        var entry: [String: Any] = ["index": i]
        if let text = provider.readBlock(at: i) {
            entry["lines"] = text.components(separatedBy: "\n").count
            entry["chars"] = text.count
        }
        blocks.append(entry)
    }

    reply(["blocks": blocks, "count": provider.blockCount])
}
```

- [ ] **Step 3: Implement surface.copy_output_block command**

```swift
/// Copy an output block to clipboard or return its text.
/// Args: index (uint, default: last), clipboard (bool, default: true)
/// Returns: { "text": "...", "index": N }
private func v2SurfaceCopyOutputBlock(
    _ args: [String: Any],
    reply: @escaping (Any?) -> Void
) {
    let (surface, _) = resolveTerminalSurface(args)
    guard let surface else {
        reply(["error": "no_surface"])
        return
    }

    let provider = OutputBlockProvider(surface: surface)
    provider.refresh()
    defer { provider.invalidate() }

    let blockCount = provider.blockCount
    guard blockCount > 0 else {
        reply(["error": "no_output_blocks"])
        return
    }

    // Default to last (most recent) block.
    let index: UInt32
    if let rawIndex = args["index"] {
        if let i = rawIndex as? Int, i >= 0, i < blockCount {
            index = UInt32(i)
        } else if let s = rawIndex as? String, s == "last" {
            index = blockCount - 1
        } else if let s = rawIndex as? String, s == "all" {
            // Copy all blocks.
            guard let text = provider.readAllBlocks() else {
                reply(["error": "read_failed"])
                return
            }
            let copyToClipboard = (args["clipboard"] as? Bool) ?? true
            if copyToClipboard {
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            reply([
                "text": text,
                "count": blockCount,
                "clipboard": copyToClipboard,
            ])
            return
        } else {
            reply(["error": "invalid_index"])
            return
        }
    } else {
        index = blockCount - 1
    }

    guard let text = provider.readBlock(at: index) else {
        reply(["error": "read_failed"])
        return
    }

    let copyToClipboard = (args["clipboard"] as? Bool) ?? true
    if copyToClipboard {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    reply([
        "text": text,
        "index": index,
        "clipboard": copyToClipboard,
    ])
}
```

- [ ] **Step 4: Verify compilation**

```bash
./scripts/reload.sh --tag copy-blocks
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/TerminalController.swift
git commit -m "feat: add surface.output_blocks and surface.copy_output_block socket commands

surface.output_blocks — list all output blocks with line/char counts
surface.copy_output_block — copy block by index (default: last) or 'all'"
```

---

### Task 7: Localization

**Files:**
- Modify: `Resources/Localizable.xcstrings`

All user-facing strings in the overlay must be localized per CLAUDE.md requirements.

- [ ] **Step 1: Add localization entries**

Add the following keys to `Resources/Localizable.xcstrings`:

| Key | English | Japanese |
|-----|---------|----------|
| `copy.block.button.title` | Copy | コピー |
| `copy.block.button.accessibility` | Copy block | ブロックをコピー |
| `copy.all.button.accessibility` | Copy all blocks | すべてのブロックをコピー |
| `copy.all.button.tooltip` | Copy all output | すべての出力をコピー |
| `copy.block.copied` | Copied! | コピーしました！ |

- [ ] **Step 2: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat: add localization strings for copy block overlay (en, ja)"
```

---

## Execution Notes

### What this plan does NOT cover (future work):
- **Intra-block splitting**: Claude Code runs as a single command, so its entire output is one block. Splitting by AI message boundaries within a block requires heuristic detection (looking for prompt patterns, horizontal rules) — planned as a follow-up.
- **Shift-click multi-select**: Select a range of blocks by clicking two.
- **Block highlight**: Subtle background tint on the hovered block. Can be added later by using `output_block_viewport_rows` to draw a highlight rect.
- **Keyboard shortcut**: A bindable `copy_last_output_block` action in Ghostty. Requires adding to `Binding.zig` action enum.
- **Settings**: User preference to disable the overlay, change delay timing, etc.

### Testing strategy:
- **Zig unit tests** verify `collectOutputBlocks` and `outputBlockIndexAtPin` correctness.
- **Swift compilation** verified via `reload.sh --tag`.
- **Manual testing** with a tagged debug build — hover over terminal with shell integration enabled.
- **Socket command testing** via `cmux-dev surface.copy_output_block` after launch.

### Ghostty submodule workflow:
1. Make Zig changes in `ghostty/` submodule
2. Commit and push to `manaflow-ai/ghostty` fork: `git push manaflow HEAD`
3. Update `ghostty.h` in parent repo
4. `git add ghostty ghostty.h` and commit in parent
5. Verify submodule is on a pushed branch: `cd ghostty && git merge-base --is-ancestor HEAD origin/main`

### Performance considerations:
- `collectOutputBlocks` iterates all prompts in scrollback — O(prompts). For a typical session (<1000 commands), this is sub-millisecond.
- Hover detection throttles to row changes only (no repeated work per pixel).
- 150ms delay before showing overlay prevents flicker.
- `OutputBlockProvider.refresh()` is called on each new hover row but is cheap.
