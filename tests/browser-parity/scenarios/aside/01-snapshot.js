// Snapshot representation on the form fixture: full tree, interactive tree,
// and a narrowed tree by selector.
await openTab(`${PRIMARY}/`);
const s1 = await snapshot(page);
emit("full", s1.tree);
const s2 = await snapshot(page, { interactive: true });
emit("interactive", s2.tree);
const s3 = await snapshot(page, { selector: "form" });
emit("selector-form", s3.tree);
