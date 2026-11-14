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
  var g = globalThis;
  var cmux = g.cmux;
  var { VStack, ForEach, Row, EmptyState } = g;
  function pane(render) {
    return render;
  }
  function fromWatch(w) {
    const live = () => w.value();
    live.loading = () => w.status() === "loading";
    live.error = () => w.error();
    live.refresh = () => void w.refresh();
    return live;
  }
  function workspaces() {
    return fromWatch(cmux.watch("workspace.list"));
  }

  // src/main.ts
  var exports_main = {};
  __export(exports_main, {
    renderPane: () => renderPane
  });
  var renderPane = pane(() => {
    const spaces = workspaces();
    return VStack({ spacing: 2 }, [
      ForEach({ items: () => spaces() ?? [], key: (w) => w.id }, (w) => Row({ title: () => w().name, symbol: () => w().focused ? "rectangle.inset.filled" : "rectangle" })),
      () => spaces.error() ? EmptyState({ title: "Can't read workspaces", message: spaces.error().message, symbol: "exclamationmark.triangle" }) : null
    ]);
  });
  globalThis.__cmuxAppExports = { ...exports_main };
})();
