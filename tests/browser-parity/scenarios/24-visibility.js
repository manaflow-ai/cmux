// What a user can see, names that do not repeat their content, and table
// shapes: collapsed rows (hidden=until-found), closed <details>,
// content-visibility, zero-size clipped boxes, inert, aria-hidden; content
// names only on leaf roles; data rows as "a | b", layout tables flattened;
// link URLs only with { urls: true }; empty lists dropped.
// oracle: skip (snapshot text is cmux-defined)
await page.goto(`${PRIMARY}/visibility.html`);
const s = await snapshot();
emitCmux("full", s.tree);
emitCmux("urls", (await snapshot(page.locator("ul").first(), { urls: true })).tree);
emitCmux("interactive", (await snapshot({ interactive: true })).tree);
emitCmux("show-hidden-has-navbox-link", (await snapshot({ showHidden: true })).tree.includes("Hidden navbox link"));
