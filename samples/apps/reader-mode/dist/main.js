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
    open: () => open,
    renderReader: () => renderReader
  });
  var KEY = "last";
  var [page, setPage] = signal(null);
  var [loading, setLoading] = signal(false);
  var [error, setError] = signal(null);
  var restored = null;
  var message = (e) => e instanceof Error ? e.message : String(e);
  function restore() {
    restored ??= (async () => {
      try {
        const last = await cmux.storage.get(KEY);
        if (last && !page())
          setPage(last);
      } catch {}
    })();
    return restored;
  }
  async function read(api, tab) {
    setLoading(true);
    try {
      const value = await api.page.read(tab ? { tab } : {});
      setPage(value);
      setError(null);
      api.storage.set(KEY, value).catch(() => {});
      return value;
    } catch (e) {
      setError(message(e));
      throw e;
    } finally {
      setLoading(false);
    }
  }
  async function open(args = {}, ctx) {
    const api = ctx?.cmux ?? cmux;
    const value = await read(api, args.tab);
    let shown = true;
    try {
      await api.actions.run("app.open", { app: cmux.app.id });
    } catch {
      shown = false;
    }
    return { title: value.article.title || value.title, url: value.url, blocks: value.article.blocks.length, shown };
  }
  var openURL = (url) => cmux.actions.run("openBrowser", { url });
  function blockView(b) {
    switch (b.kind) {
      case "heading":
        return Text(b.text).font((b.level ?? 2) <= 1 ? "title2" : (b.level ?? 2) === 2 ? "title3" : "headline");
      case "list_item":
        return HStack({ spacing: 6 }, [Text("•").secondary(), Text(b.text).font("body"), Spacer()]);
      case "quote":
        return HStack({ spacing: 8 }, [Rectangle().fill("separator").frame({ width: 3, maxHeight: "infinity" }), Text(b.text).font("body").italic().secondary(), Spacer()]);
      case "code":
        return Text(b.text).monospaced().font("callout").padding(8).frame({ maxWidth: "infinity" }).background("hover").cornerRadius(6);
      case "image": {
        const row = Row({ title: b.text || "Image", subtitle: b.src ?? null, symbol: "photo" });
        return b.src ? row.help(b.src).onTap(() => openURL(b.src)) : row;
      }
      default:
        return HStack([Text(b.text).font("body"), Spacer()]);
    }
  }
  function articleView(p) {
    const a = p.article;
    const meta = [a.byline, a.site].filter((s) => !!s && s.trim() !== "").join(" · ");
    return VStack({ spacing: 10 }, [
      Text(a.title || p.title || p.url).font("title"),
      meta ? Text(meta).font("callout").secondary() : null,
      Text(p.url).font("caption").secondary().lineLimit(1).truncation("middle"),
      Divider(),
      ...a.blocks.map(blockView),
      a.blocks.length === 0 ? EmptyState({ title: "No article text on this page", message: "Reader mode found no paragraphs here.", symbol: "doc.text" }) : null,
      p.links.length > 0 ? Divider() : null,
      p.links.length > 0 ? Text(`Links (${p.links.length})`).font("headline") : null,
      ...p.links.map((l) => Row({ title: l.text || l.href, subtitle: l.href, symbol: "link" }).help(l.href).onTap(() => openURL(l.href)))
    ]);
  }
  function renderReader() {
    restore();
    return VStack({ spacing: 12 }, [
      HStack({ spacing: 8 }, [
        Button("Read this page", () => read(cmux).catch(() => {})).disabled(loading),
        Button("Reload", () => read(cmux, page()?.tab).catch(() => {})).disabled(() => loading() || !page()),
        Button("Open original", () => openURL(page().url)).disabled(() => !page()),
        Spacer(),
        () => loading() ? ProgressView() : null
      ]),
      () => error() ? EmptyState({ title: "Cannot read this page", message: error(), symbol: "exclamationmark.triangle" }) : null,
      () => {
        const p = page();
        if (p)
          return articleView(p);
        if (loading() || error())
          return null;
        return EmptyState({ title: "No page read yet", message: "Focus a browser tab, then run Reader mode from the command palette or click Read this page.", symbol: "doc.plaintext" });
      }
    ]).padding(16);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
