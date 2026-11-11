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
    renderSection: () => renderSection
  });
  var [count, setCount] = signal(0);
  function renderSection() {
    return VStack([
      Panel({ title: "Hello" }, [
        Text(() => `Clicked ${count()} times`),
        HStack([
          Button("Click", () => setCount((n) => n + 1)),
          Spacer(),
          Button("Say hi", () => cmux.toast({ title: "Hi from my extension", tone: "success" }))
        ])
      ])
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
