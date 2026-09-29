// Role, name, state and visibility rules on the ARIA fixture.
await openTab(`${PRIMARY}/aria.html`);
emit("full", (await snapshot(page)).tree);
emit("interactive", (await snapshot(page, { interactive: true })).tree);
emit("show-hidden", (await snapshot(page, { showHidden: true })).tree);
