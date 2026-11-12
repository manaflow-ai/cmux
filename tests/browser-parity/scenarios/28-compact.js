// Compactness rules: elements clipped out
// by an overflow:hidden ancestor are left out (a positioned popup that escapes
// the clipper is kept), punctuation-only text folds away, closed selects list
// options inline (capped), header rows are marked, unnamed or image-only links
// show their URL, interactive mode keeps headings and landmarks, a changed
// line prints once as "~", a small snapshot prints its diff when shorter,
// and { viewport: true } keeps what intersects the viewport.
// oracle: skip (snapshot text is cmux-defined)
// ---- cell session=compact
await page.setViewportSize({ width: 1280, height: 800 });
await page.goto(`${PRIMARY}/compact.html`);
emitCmux("full", (await snapshot()).tree);
emitCmux("interactive", (await snapshot({ interactive: true })).tree);
emitCmux("viewport", (await snapshot({ viewport: true })).tree);
// ---- cell session=compact capture
await page.getByRole("textbox", { name: "Email" }).fill("me@x.com");
await snapshot({ interactive: true })
