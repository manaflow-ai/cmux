// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    copyNote: () => copyNote,
    newNote: () => newNote,
    noteCorpus: () => noteCorpus,
    noteDetail: () => noteDetail,
    openNote: () => openNote,
    searchNotes: () => searchNotes
  });
  var APP = "app:cmux/palette-notes";
  var INLINE_COPY = 300;
  var readNotes = async (options) => await cmux.call("app.storage.get", { key: "notes" }, options) ?? [];
  var firstLine = (text) => text.split(`
`, 1)[0].slice(0, 120);
  function excerpt(body, needle) {
    const at = body.toLowerCase().indexOf(needle);
    if (at < 0)
      return firstLine(body);
    const start = Math.max(0, at - 30);
    return `${start > 0 ? "…" : ""}${body.slice(start, at + needle.length + 60).replace(/\s+/g, " ")}`;
  }
  function toItem(n, subtitle) {
    return {
      id: n.id,
      title: n.title,
      subtitle: subtitle ?? n.folder ?? firstLine(n.body),
      symbol: n.pinned ? "pin.fill" : "note.text",
      keywords: n.tags ?? [],
      accessory: { date: n.updatedAt },
      actions: [act(`${APP}#open`, { id: n.id }), n.body.length <= INLINE_COPY ? act("clipboard.write", { text: n.body }, { symbol: "doc.on.doc" }) : act(`${APP}#copy`, { id: n.id })]
    };
  }
  var byPinnedThenRecent = (a, b) => Number(!!b.pinned) - Number(!!a.pinned) || b.updatedAt - a.updatedAt;
  var noteCorpus = palette.snapshot(async () => (await readNotes()).sort(byPinnedThenRecent).slice(0, 1e4).map((n) => toItem(n)));
  var searchNotes = palette.query(async function* (query, { signal }) {
    yield palette.cached();
    const notes = (await readNotes({ signal })).sort(byPinnedThenRecent);
    const needle = query.trim().toLowerCase();
    const inTitle = notes.filter((n) => n.title.toLowerCase().includes(needle));
    yield inTitle.slice(0, 200).map((n) => toItem(n));
    const inBody = notes.filter((n) => !inTitle.includes(n) && n.body.toLowerCase().includes(needle));
    yield inBody.slice(0, 200).map((n) => toItem(n, excerpt(n.body, needle)));
  });
  var noteDetail = palette.detail(async (id) => {
    const note = (await readNotes()).find((n) => n.id === id);
    return note ? { markdown: `# ${note.title}

${note.body}`, actions: toItem(note).actions } : null;
  });
  async function newNote(args, ctx) {
    const notes = await readNotes();
    const next = Number(await ctx.cmux.storage.get("nextId") ?? notes.length + 1);
    const note = { id: `n${next}`, title: args.title.trim(), body: args.body ?? "", updatedAt: Date.now() };
    await ctx.cmux.storage.set("notes", [...notes, note]);
    await ctx.cmux.storage.set("nextId", next + 1);
    return { id: note.id };
  }
  async function openNote(args, ctx) {
    const note = (await readNotes()).find((n) => n.id === args.id);
    if (!note)
      throw new CmuxError("note.missing", `no note ${args.id}`);
    const recent = await ctx.cmux.storage.get("recent") ?? [];
    await ctx.cmux.storage.set("recent", [note.id, ...recent.filter((id) => id !== note.id)].slice(0, 20));
    return { id: note.id, title: note.title };
  }
  async function copyNote(args, ctx) {
    const note = (await readNotes()).find((n) => n.id === args.id);
    if (!note)
      throw new CmuxError("note.missing", `no note ${args.id}`);
    await ctx.cmux.call("clipboard.write", { text: note.body });
    return { id: note.id };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
