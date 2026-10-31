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
    add: () => add,
    clear: () => clear,
    list: () => list
  });
  var KEY = "notes";
  async function notes() {
    return (await cmux.storage.get(KEY) ?? []).filter((n) => typeof n?.text === "string");
  }
  async function add(args = {}) {
    const text = String(args.text ?? "").trim();
    if (!text)
      throw new Error("text is empty");
    const next = [...await notes(), { at: new Date().toISOString(), text }];
    await cmux.storage.set(KEY, next);
    return { count: next.length };
  }
  async function list() {
    const all = await notes();
    return { count: all.length, notes: all };
  }
  async function clear() {
    const count = (await notes()).length;
    await cmux.storage.delete(KEY);
    return { cleared: count };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
