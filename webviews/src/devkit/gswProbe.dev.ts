// TEMPORARY (cmux#50535 bench instrumentation, removed before land): what the Vite client does in this
// page, sent over its own HMR socket to dev-server/gswProbe.ts.
const page = `${location.protocol}//${location.host}${location.pathname}`;
const send = (event: string, fields: Record<string, unknown> = {}) => {
  try {
    import.meta.hot?.send("gsw:probe", {
      event,
      page,
      at: Date.now(),
      visible: document.visibilityState,
      ...fields,
    });
  } catch {}
};
if (import.meta.hot) {
  const navigation = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming | undefined;
  send("load", { type: navigation?.type ?? "unknown", ready: document.readyState });
  addEventListener("load", () => send("window-load"));
  import.meta.hot.on("vite:ws:connect", () => send("ws-connect"));
  import.meta.hot.on("vite:ws:disconnect", () => send("ws-disconnect"));
  import.meta.hot.on("vite:beforeUpdate", (payload) =>
    send("before-update", { paths: payload.updates.map((u) => u.path).slice(0, 10) }),
  );
  import.meta.hot.on("vite:afterUpdate", (payload) => {
    const paths = payload.updates.map((u) => u.path).slice(0, 10);
    send("after-update", { paths });
    requestAnimationFrame(() => requestAnimationFrame(() => send("after-update-painted", { paths })));
  });
  import.meta.hot.on("vite:beforeFullReload", (payload) => send("before-full-reload", { path: payload.path ?? null }));
  import.meta.hot.on("vite:error", (payload) =>
    send("error", { message: String(payload.err?.message ?? "").slice(0, 300) }),
  );
  import.meta.hot.on("vite:invalidate", (payload) =>
    send("invalidate", { path: payload.path, message: payload.message ?? null }),
  );
  document.addEventListener("visibilitychange", () => send("visibility"));
}
