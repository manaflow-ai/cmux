# Composer caret beside attachments

Leo, 2026-11-12: “the caret bounces between the text and attachment thing size when it's between two. That's not good.”

The insertion caret is the text line's height before, after and between inline attachments, and
inside the surrounding words. Attachment dimensions, zoom and a soft wrap do not change that
height. Its horizontal position follows the browser's insertion point, including which side of
a soft wrap the person reached. A range or selected attachment draws no insertion caret.

Reference: `cmux-design-references/apps/cmux/live/composer-attachment-caret-clearance.png`.
Keep the chip's size, baseline and clearance; the fix must not shrink thumbnails, add characters
to the draft, or change attachment selection, drag, undo or copy.

WebKit paints a native caret across a tall inline atom's line box. The editor's caret geometry
therefore uses the paragraph's text line height and the words' vertical position throughout a
paragraph containing attachments, without testing for one particular neighboring pair. Empty
attachment lines align to the line's foot. CSS zoom converts viewport coordinates back into the
field's coordinates. The caret follows focus, page key state, composition and chip image loads;
plain paragraphs keep the browser's caret. The strip view keeps its native text caret.

Detector: `webviews/test/composer-inline-caret-height.browser.test.ts` measures the painted caret
in WebKit and Chromium, including zoom. The `agent-pane.composer` gallery's
`attachment-inline-caret` and `attachment-inline-reorder` scenes supply text/chip and chip/chip
boundaries.
