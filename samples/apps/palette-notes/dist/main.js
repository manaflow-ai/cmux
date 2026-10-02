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
  var ITEM_BYTES = 2048;
  var INLINE_COPY_BYTES = 600;
  var MAX_TAGS = 8;
  var MAX_TAG = 32;
  var MAX_TEXT = 120;
  function utf8Bytes(text) {
    let n = 0;
    for (const ch of text) {
      const c = ch.codePointAt(0);
      n += c < 128 ? 1 : c < 2048 ? 2 : c < 65536 ? 3 : 4;
    }
    return n;
  }
  var clip = (text, max) => Array.from(text).length > max ? `${Array.from(text).slice(0, max - 1).join("")}…` : text;
  var readNotes = async (options) => await cmux.call("app.storage.get", { key: "notes" }, options) ?? [];
  var firstLine = (text) => clip(text.split(`
`, 1)[0], MAX_TEXT);
  function excerpt(body, needle) {
    const at = body.toLowerCase().indexOf(needle);
    if (at < 0)
      return firstLine(body);
    const start = Math.max(0, at - 30);
    return `${start > 0 ? "…" : ""}${body.slice(start, at + needle.length + 60).replace(/\s+/g, " ")}`;
  }
  function toItem(n, subtitle) {
    const copy = utf8Bytes(n.body) <= INLINE_COPY_BYTES ? act("clipboard.write", { text: n.body }, { symbol: "doc.on.doc" }) : act(`${APP}#copy`, { id: n.id });
    const item = {
      id: n.id,
      title: clip(n.title, MAX_TEXT),
      subtitle: clip(subtitle ?? n.folder ?? firstLine(n.body), MAX_TEXT),
      symbol: n.pinned ? "pin.fill" : "note.text",
      keywords: (n.tags ?? []).slice(0, MAX_TAGS).map((t) => clip(t, MAX_TAG)),
      accessory: { date: n.updatedAt },
      actions: [act(`${APP}#open`, { id: n.id }), copy]
    };
    if (utf8Bytes(JSON.stringify(item)) <= ITEM_BYTES)
      return item;
    item.actions = [act(`${APP}#open`, { id: n.id }), act(`${APP}#copy`, { id: n.id })];
    return utf8Bytes(JSON.stringify(item)) <= ITEM_BYTES ? item : null;
  }
  var rows = (notes, subtitle) => notes.map((n) => toItem(n, subtitle?.(n))).filter((i) => i !== null);
  var byPinnedThenRecent = (a, b) => Number(!!b.pinned) - Number(!!a.pinned) || b.updatedAt - a.updatedAt;
  var noteCorpus = palette.snapshot(async () => rows((await readNotes()).sort(byPinnedThenRecent).slice(0, 1e4)));
  var searchNotes = palette.query(async function* (query, { signal }) {
    yield palette.cached();
    const notes = (await readNotes({ signal })).sort(byPinnedThenRecent);
    const needle = query.trim().toLowerCase();
    const inTitle = notes.filter((n) => n.title.toLowerCase().includes(needle));
    yield rows(inTitle.slice(0, 200));
    const inBody = notes.filter((n) => !inTitle.includes(n) && n.body.toLowerCase().includes(needle));
    yield rows(inBody.slice(0, 200), (n) => excerpt(n.body, needle));
  });
  var noteDetail = palette.detail(async (id) => {
    const note = (await readNotes()).find((n) => n.id === id);
    return note ? { markdown: `# ${note.title}

${note.body}`, actions: toItem(note)?.actions ?? [act(`${APP}#open`, { id: note.id })] } : null;
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
