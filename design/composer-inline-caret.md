# Composer caret beside attachments

Leo, 2026-11-12: “the caret bounces between the text and attachment thing size when it's between two. That's not good.”

The insertion caret is the text line's height before, after and between inline attachments, and
inside the surrounding words. Attachment dimensions, zoom and a soft wrap do not change that
height. Its horizontal position follows the browser's insertion point, including which side of
a soft wrap the person reached. A range or selected attachment draws no insertion caret.

Reference: `cmux-design-references/apps/cmux/live/composer-attachment-caret-clearance.png`.
The caret fix preserves each attachment's dimensions, baseline and clearance; it must not add
characters to the draft or change attachment selection, drag, undo or copy. Image sizing follows
the separate compact-image contract below.

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

## Compact images in the prompt (#38135)

The issue's expected behavior is: “a pasted image shows as a small attachment chip/thumbnail and
the composer stays at normal single-line text height; it grows only with typed text.”

A healthy inline image occupies one prompt text line, including while its bytes are loading.
The atom adds no vertical margin; the thumbnail inherits the actual text line height in either
composer look and at larger font sizes. Text can still wrap and add newlines. Rest shows the
thumbnail; hover and keyboard focus reveal its existing remove control, leaving the center free
for opening and dragging. Selection, undo, sending, strip view, videos and failed-image retry
tiles keep their existing behavior.

The detector is `composer-inline-caret-height.browser.test.ts`: the compact gallery scenes
measure empty/text/pair composers in chat, New Tab and Quick Composer, in both looks, before
paste, during a held image read, and after the read;
typed newlines must then grow the composer. `composer-inline-reorder.browser.test.ts` verifies
that the image center remains draggable and the remove control remains reachable.
