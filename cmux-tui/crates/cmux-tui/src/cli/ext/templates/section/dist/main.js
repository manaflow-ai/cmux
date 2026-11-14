// The packer's build of src/main.ts, so this folder loads before bun is installed. `cmux ext dev`
// rebuilds it on every save. Do not edit; edit src/main.ts.
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
  var g = globalThis;
  var cmux = g.cmux;
  var { signal } = g;
  var { VStack, HStack, Text, Button, Spacer, Panel } = g;
  function section(render) {
    return render;
  }

  // src/main.ts
  var exports_main = {};
  __export(exports_main, {
    renderSection: () => renderSection
  });
  var [count, setCount] = signal(0);
  var renderSection = section(() => VStack([
    Panel({ title: "Hello" }, [
      Text(() => `Clicked ${count()} times`),
      HStack([
        Button("Click", () => setCount((n) => n + 1)),
        Spacer(),
        Button("Say hi", () => cmux.toast({ title: "Hi from my extension", tone: "success" }))
      ])
    ])
  ]));
  globalThis.__cmuxAppExports = { ...exports_main };
})();
