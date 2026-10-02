// Roles, names, states and visibility on the ARIA fixture.
// oracle: skip (snapshot text is cmux-defined)
await page.goto(`${PRIMARY}/aria.html`);
emitCmux("full", (await snapshot()).tree);
emitCmux("interactive", (await snapshot({ interactive: true })).tree);
emitCmux("show-hidden", (await snapshot({ showHidden: true })).tree);
