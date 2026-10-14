// Targets an agent must see right: zero-size links left out unless content
// inside shows, a <summary> disclosure keeps its name although it holds a
// link, names that repeat their text in another case print once, off-site
// links say where they go, brackets around a clipped link close up, and an
// interactive diff after a submit shows the result text.
// oracle: skip (snapshot text is cmux-defined)
// ---- cell session=targets
await page.setViewportSize({ width: 1280, height: 800 });
await page.goto(`${PRIMARY}/targets.html`);
emitCmux("full", (await snapshot()).tree);
await snapshot({ interactive: true });
// ---- cell session=targets capture
await page.getByRole("textbox", { name: "Email" }).fill("me@x.com");
await page.getByRole("button", { name: "Send" }).click();
await snapshot({ interactive: true })
