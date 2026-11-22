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
    cycleVariant: () => cycleVariant,
    open: () => open,
    revert: () => revert,
    save: () => save,
    toggleReadOnly: () => toggleReadOnly
  });
  var EDITOR_INTERFACE = "cmux.editor/1";
  var EDITOR_VARIANTS = ["statusLine", "header", "bare"];
  var normalizeVariant = (v) => EDITOR_VARIANTS.includes(v) ? v : "statusLine";
  var invalid = (message) => new CmuxError("invalid_params", message);
  var str = (v) => typeof v === "string" && v.trim() ? v.trim() : undefined;
  var paneCommand = (command, args = {}) => cmux.call("app.pane.command", { kind: "editor", command, args });
  async function open(args = {}) {
    const uri = str(args.uri);
    let doc = str(args.doc);
    if (!uri && !doc)
      throw invalid("give uri or doc");
    if (!doc)
      doc = (await cmux.call("document.open", { uri })).info.doc;
    await cmux.call("app.pane.open", { kind: "editor", props: { doc }, interface: EDITOR_INTERFACE });
    return { doc };
  }
  async function save(args = {}) {
    const doc = str(args.doc);
    if (!doc)
      return paneCommand("save");
    const opened = await cmux.call("document.open", { doc });
    if (!opened.info.dirty)
      return { doc, saved: false, reason: "clean" };
    await cmux.call("document.save", { doc, revision: opened.info.revision });
    return { doc, saved: true };
  }
  async function revert(args = {}) {
    const doc = str(args.doc);
    if (!doc)
      return paneCommand("revert");
    await cmux.call("document.revert", { doc });
    return { doc, reverted: true };
  }
  async function toggleReadOnly() {
    return paneCommand("toggleReadOnly");
  }
  async function cycleVariant() {
    const current = normalizeVariant(cmux.app.settings().variant);
    const next = EDITOR_VARIANTS[(EDITOR_VARIANTS.indexOf(current) + 1) % EDITOR_VARIANTS.length];
    try {
      await cmux.call("app.settings.set", { key: "variant", value: next });
      return { variant: next, persisted: true };
    } catch {
      return { variant: next, persisted: false };
    }
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
