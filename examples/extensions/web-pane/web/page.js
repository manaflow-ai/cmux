// ../../../cmux-tui/crates/cmux-extension-sdk/typescript/src/web.ts
class CmuxCallError extends Error {
  code;
  retryable;
  constructor(code, message, retryable) {
    super(message ? `${code}: ${message}` : code);
    this.name = "CmuxCallError";
    this.code = code;
    this.retryable = retryable;
  }
}
function pageHost() {
  const host = globalThis.webkit?.messageHandlers?.cmuxPage;
  if (!host)
    throw new CmuxCallError("page.unhosted", "this page is not open in cmux", false);
  return host;
}
var nextId = 0;
async function call(op, params = {}) {
  nextId += 1;
  const reply = await pageHost().postMessage({ t: "call", id: nextId, op: `${location.host}.${op}`, params });
  if (reply.t === "ok")
    return reply.value;
  throw new CmuxCallError(reply.code, reply.message ?? "", reply.retryable ?? false);
}
var storage = {
  get: (key) => call("app.storage.get", { key }),
  set: (key, value) => call("app.storage.set", { key, value })
};

// src/page.ts
var byId = (id) => document.getElementById(id);
async function showWorkspaces() {
  const list = byId("workspaces");
  try {
    const value = await call("workspace.list");
    const workspaces = Array.isArray(value) ? value : value.workspaces ?? [];
    list.replaceChildren(...workspaces.map((w) => Object.assign(document.createElement("li"), { textContent: w.name ?? w.title ?? w.id })));
    if (workspaces.length === 0)
      list.replaceChildren(Object.assign(document.createElement("li"), { textContent: "No workspaces", className: "muted" }));
  } catch (error) {
    list.replaceChildren(Object.assign(document.createElement("li"), { textContent: String(error), className: "muted" }));
  }
}
async function keepNote() {
  const note = byId("note");
  note.value = await storage.get("note").catch(() => null) ?? "";
  let pending;
  note.addEventListener("input", () => {
    clearTimeout(pending);
    pending = setTimeout(() => void storage.set("note", note.value), 300);
  });
}
byId("rename").addEventListener("click", async () => {
  const out = byId("refusal");
  try {
    await call("workspace.rename", { workspace: "current", name: "Renamed by a web pane" });
    out.textContent = "Renamed (this should not happen)";
  } catch (error) {
    out.textContent = error instanceof CmuxCallError ? `Refused: ${error.code}` : String(error);
  }
});
showWorkspaces();
keepNote();
