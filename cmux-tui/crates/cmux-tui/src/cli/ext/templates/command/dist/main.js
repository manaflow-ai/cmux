// The first build of src/main.ts, written by hand so the new extension loads before bun is
// installed; `cmux ext dev` replaces it with its own bundle on the first change. Do not edit.
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

  // sdk/src/index.ts
  function command(run) {
    return run;
  }

  // src/main.ts
  var exports_main = {};
  __export(exports_main, {
    hello: () => hello
  });
  var hello = command(async (args, { cmux }) => {
    const greeting = `Hello, ${args.name ?? "you"}`;
    await cmux.toast({ title: greeting, tone: "success" });
    return { greeting };
  });
  globalThis.__cmuxAppExports = { ...exports_main };
})();
