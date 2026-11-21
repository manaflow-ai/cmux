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
    clear: () => clear,
    follow: () => follow,
    renderHints: () => renderHints,
    show: () => show,
    showSplit: () => showSplit
  });
  var [hints, setHints] = signal(null);
  var [newSplit, setNewSplit] = signal(false);
  var [typed, setTyped] = signal("");
  var [error, setError] = signal(null);
  var hintedTab;
  var message = (e) => e instanceof Error ? e.message : String(e);
  var norm = (s) => s.trim().toLowerCase();
  var onTab = () => hintedTab ? { tab: hintedTab } : {};
  async function show(args = {}, ctx) {
    const api = ctx?.cmux ?? cmux;
    try {
      const r = await api.page.hints({ action: "show" });
      hintedTab = r.tab;
      setHints(r.hints);
      setNewSplit(args.new_split === true);
      setTyped("");
      setError(r.hints.length === 0 ? "No links on this page" : null);
      return { hints: r.hints, new_split: args.new_split === true };
    } catch (e) {
      setHints(null);
      setError(message(e));
      throw e;
    }
  }
  async function showSplit(_args = {}, ctx) {
    return show({ new_split: true }, ctx);
  }
  async function follow(args = {}, ctx) {
    const typedLabel = String(args.label ?? "").trim();
    if (!typedLabel)
      throw new Error("label is empty");
    const label = (hints() ?? []).find((h) => h.label.toLowerCase() === typedLabel.toLowerCase())?.label ?? typedLabel;
    const api = ctx?.cmux ?? cmux;
    const r = await api.page.follow({ ...onTab(), label, new_split: args.new_split ?? newSplit() });
    hintedTab = undefined;
    setHints(null);
    setTyped("");
    setError(r.followed ? null : `No link labeled ${label}`);
    return r;
  }
  async function clear(_args = {}, ctx) {
    const api = ctx?.cmux ?? cmux;
    const tab = onTab();
    hintedTab = undefined;
    setHints(null);
    setTyped("");
    setError(null);
    await api.page.hints({ ...tab, action: "clear" });
    return { cleared: true };
  }
  var matching = () => {
    const t = norm(typed());
    return (hints() ?? []).filter((h) => h.label.toLowerCase().startsWith(t));
  };
  var pick = (label) => follow({ label }).catch((e) => setError(message(e)));
  var cancel = () => clear().catch((e) => setError(message(e)));
  function onEdit(text) {
    setTyped(text);
    const t = norm(text);
    const all = hints() ?? [];
    const exact = all.find((h) => h.label.toLowerCase() === t);
    if (exact && !all.some((h) => h !== exact && h.label.toLowerCase().startsWith(t)))
      pick(exact.label);
  }
  function onSubmit(text) {
    const t = norm(text);
    const exact = (hints() ?? []).find((h) => h.label.toLowerCase() === t);
    const only = matching().length === 1 ? matching()[0] : undefined;
    const hit = exact ?? only;
    if (hit)
      pick(hit.label);
    else
      setError(`No link labeled ${text.trim()}`);
  }
  function picker() {
    return VStack({ spacing: 6 }, [
      Text(() => newSplit() ? "Type a label to open it in a new split" : "Type a label to follow it").font("callout").secondary(),
      TextField(typed, { placeholder: "Label", autofocus: true, onEdit, onSubmit, onCancel: cancel }),
      () => error() ? Text(error()).font("caption").color("danger") : null,
      ForEach({ items: matching, key: (h) => h.label }, (h) => Row({ title: () => h().text || h().href || h().label, subtitle: () => h().href, badge: () => h().label, symbol: "link" }).help(() => h().href ?? h().text).onTap(() => pick(h().label))),
      HStack([Spacer(), Button("Cancel", cancel).help("Escape")])
    ]);
  }
  function idle() {
    return VStack({ spacing: 6 }, [
      () => error() ? EmptyState({ title: "No link hints", message: error(), symbol: "exclamationmark.triangle" }) : null,
      HStack({ spacing: 8 }, [
        Button("Show link hints", () => show().catch(() => {})),
        Button("Open in new split", () => showSplit().catch(() => {})),
        Spacer()
      ])
    ]);
  }
  function renderHints() {
    return VStack({ spacing: 0 }, [() => hints() && hints().length > 0 ? picker() : idle()]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
