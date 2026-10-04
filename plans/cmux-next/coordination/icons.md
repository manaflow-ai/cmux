# Lane: icons

## Active streams
- Icons lead (R94, plans/cmux-next/icons.md). Daemon icon assets (`put-blob`/`get-blob`, `icon-assets-v1`, `image:`/`svg:` icon forms, quick-xml SVG sanitizer) wait on branch feat-cmux-next-icon-assets for a green Testbox gate and a WINDOW-LITE window (Cargo.lock edge cmux-tui-core -> quick-xml 0.41.0, spec and SDK files). The shared prewarmed page host (shell) is on branch feat-cmux-next-pagehost, reviewed by the React UIs lead before it lands.

## Rules
- Icon blobs are local to each registry and do not sync (coordinator, 2026-10-04). A replica that has an icon value without its blob draws the default icon for that object kind, never a blank or a broken image, and increments one debug counter. The sync lane adds a blob fetch by hash later (content addressed, so a fetch by hash is safe).
- Every new icon field (for example the sidebar-layout store, PR 16842) must be added to the daemon's ICON_REFERENCE_FIELDS, or the blob sweep deletes its assets.
- One icon rule: Swift `IconValue` (CmuxNextDesign), page `iconValue.ts`, daemon `validate_presentation_icon`. Do not add another "is this an emoji" check.

## Landed
- 2026-10-04 bd9745a8551 icon picker React page (stand-alone); 7e7e09a5533 vp check fix; 1c194a0f998 IconValue, icon with color, Settings icon kinds, Set Icon opens the picker (workspace, screen, space, browser profile).
