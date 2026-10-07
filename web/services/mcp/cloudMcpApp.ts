// The cmux Cloud MCP App: one HTML view that ChatGPT renders in the sidebar
// (global entrypoint), in a conversation panel (thread entrypoint), and inline
// under list_machines, create_machine, run_agent and read_terminal results.
//
// It speaks MCP Apps JSON-RPC over postMessage directly (ui/initialize,
// tools/call, ui/open-link, ui/message, ui/update-model-context), so it needs
// no bundle and fetches nothing: every action is a tool call through the host,
// which applies the same OAuth scopes as a model call. Deep links are
// app-relative paths: `/`, `/machines/<id>`, `/machines/<id>/terminals/<id>`.

import { CLOUD_MCP_APP_URI } from "./cloudMcpCloudTools";

const APP_STYLE = `
:root { color-scheme: light dark; --bg: #fff; --fg: #0d0d0d; --muted: #6b6b6b; --line: rgba(0,0,0,.1); --card: rgba(0,0,0,.03); --accent: #0d0d0d; --accent-fg: #fff; --danger: #c4314b; --ok: #1a7f37; }
:root[data-theme="dark"] { --bg: #212121; --fg: #ececec; --muted: #9b9b9b; --line: rgba(255,255,255,.12); --card: rgba(255,255,255,.04); --accent: #ececec; --accent-fg: #0d0d0d; --danger: #ff6b81; --ok: #4ac26b; }
* { box-sizing: border-box; }
body { margin: 0; font: 14px/1.45 var(--font-sans, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif); color: var(--color-text-primary, var(--fg)); background: transparent; }
main { padding: 16px; max-width: 960px; margin: 0 auto; }
h1 { font-size: 18px; font-weight: 600; margin: 0; }
h2 { font-size: 14px; font-weight: 600; margin: 20px 0 8px; }
.muted { color: var(--muted); }
.row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.spread { justify-content: space-between; }
.card { border: 1px solid var(--line); background: var(--card); border-radius: 12px; padding: 12px; }
.list { display: grid; gap: 8px; }
.machine { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pill { font-size: 12px; border-radius: 999px; padding: 1px 8px; border: 1px solid var(--line); }
.pill.running { color: var(--ok); border-color: currentColor; }
button, select, input, textarea { font: inherit; color: inherit; }
button { border: 1px solid var(--line); background: transparent; border-radius: 999px; padding: 5px 12px; cursor: pointer; }
button:hover { background: var(--card); }
button.primary { background: var(--accent); color: var(--accent-fg); border-color: var(--accent); }
button.danger { color: var(--danger); }
button:disabled { opacity: .5; cursor: default; }
input, select, textarea { border: 1px solid var(--line); background: transparent; border-radius: 8px; padding: 6px 10px; }
textarea { width: 100%; min-height: 72px; resize: vertical; }
pre.term { margin: 0; padding: 12px; border-radius: 10px; background: #0d0d0d; color: #e6e6e6; font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; overflow: auto; max-height: 420px; white-space: pre; }
.notice { border-left: 3px solid var(--muted); padding: 8px 12px; margin: 12px 0; }
.error { color: var(--danger); }
a { color: inherit; }
`;

const APP_SCRIPT = String.raw`
(() => {
  const state = { confirmDelete: null, hostContext: {}, account: null, machines: [], route: "/", busy: false, error: null, terminal: null, terminals: null, poll: null };
  const root = document.getElementById("root");
  let nextId = 1;
  const pending = new Map();

  function send(message) { window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*"); }
  function request(method, params) {
    const id = nextId++;
    send({ id, method, params });
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }
  function notify(method, params) { send({ method, params }); }

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || data.jsonrpc !== "2.0") return;
    if (data.id !== undefined && pending.has(data.id) && !data.method) {
      const entry = pending.get(data.id); pending.delete(data.id);
      if (data.error) entry.reject(new Error(data.error.message || "Request failed")); else entry.resolve(data.result);
      return;
    }
    if (data.method === "ui/notifications/tool-result") applyToolResult(data.params);
    else if (data.method === "ui/notifications/host-context-changed") applyHostContext(data.params || {});
    else if (data.method === "ui/resource-teardown") { stopPolling(); if (data.id !== undefined) send({ id: data.id, result: {} }); }
    else if (data.method === "ping" && data.id !== undefined) send({ id: data.id, result: {} });
  });

  function applyHostContext(context) {
    Object.assign(state.hostContext, context);
    if (context.theme) document.documentElement.dataset.theme = context.theme;
    const vars = context.styles && context.styles.variables;
    if (vars) for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
    const link = context["openai/deepLink"];
    if (link && typeof link.url === "string") navigate(link.url, false);
  }

  function applyToolResult(result) {
    const data = (result && result.structuredContent) || {};
    if (result && result.isError) { state.error = data; render(); return; }
    state.error = null;
    if (data.account) state.account = data.account;
    if (Array.isArray(data.machines)) state.machines = data.machines;
    if (data.view === "machine" && data.machine) { upsertMachine(data.machine); state.route = "/machines/" + data.machine.id; }
    if (data.view === "terminal" && data.terminal_id) {
      state.route = "/machines/" + data.machine_id + "/terminals/" + data.terminal_id;
      state.terminal = { machineId: data.machine_id, terminalId: data.terminal_id, text: data.source ? textOf(result) : "" };
    }
    render();
    if (data.view === "terminal") startPolling();
  }

  function upsertMachine(machine) {
    const index = state.machines.findIndex((m) => m.id === machine.id);
    if (index >= 0) state.machines[index] = { ...state.machines[index], ...machine }; else state.machines.unshift(machine);
  }

  async function callTool(name, args) {
    state.busy = true; render();
    try {
      const result = await request("tools/call", { name, arguments: args || {} });
      if (result && result.isError) { state.error = result.structuredContent || { message: textOf(result) }; return null; }
      state.error = null;
      return result;
    } catch (error) {
      state.error = { message: String(error && error.message || error) };
      return null;
    } finally { state.busy = false; render(); }
  }

  function textOf(result) { return (result && result.content || []).map((c) => c.text || "").join("\n"); }

  async function refresh() {
    const result = await callTool("open_cloud", {});
    if (result) applyToolResult(result);
  }

  function parseRoute(path) {
    const parts = path.split("?")[0].split("/").filter(Boolean);
    if (parts[0] === "machines" && parts[1]) return { machineId: decodeURIComponent(parts[1]), terminalId: parts[2] === "terminals" && parts[3] ? decodeURIComponent(parts[3]) : null };
    return { machineId: null, terminalId: null };
  }

  function navigate(path, load = true) {
    stopPolling();
    state.route = path || "/";
    const route = parseRoute(state.route);
    state.terminals = null;
    if (!route.terminalId) state.terminal = null;
    publishContext(route);
    render();
    if (!load) { if (route.machineId && !state.machines.length) refresh(); }
    if (route.machineId && !route.terminalId) loadTerminals(route.machineId);
    if (route.terminalId) { state.terminal = state.terminal && state.terminal.terminalId === route.terminalId ? state.terminal : { machineId: route.machineId, terminalId: route.terminalId, text: "" }; readTerminal(); startPolling(); }
  }

  function publishContext(route) {
    const machine = state.machines.find((m) => m.id === route.machineId);
    const parts = [];
    if (machine) parts.push("Selected cmux Cloud machine: " + (machine.name || machine.id) + " (id " + machine.id + ", " + machine.status + ").");
    if (route.terminalId) parts.push("Selected terminal: " + route.terminalId + " on machine " + route.machineId + ".");
    request("ui/update-model-context", parts.length ? { content: [{ type: "text", text: parts.join(" ") }] } : { content: [] }).catch(() => {});
  }

  async function loadTerminals(machineId) {
    const result = await callTool("list_terminals", { machine_id: machineId });
    state.terminals = result && result.structuredContent ? result.structuredContent.terminals || [] : [];
    render();
  }

  async function readTerminal() {
    const t = state.terminal; if (!t) return;
    try {
      const result = await request("tools/call", { name: "read_terminal", arguments: { machine_id: t.machineId, terminal_id: t.terminalId } });
      if (state.terminal !== t) return;
      if (result && !result.isError) { t.text = textOf(result); render(); }
    } catch {}
  }

  function startPolling() { stopPolling(); state.poll = setInterval(() => { if (!document.hidden) readTerminal(); }, 2500); }
  function stopPolling() { if (state.poll) clearInterval(state.poll); state.poll = null; }

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
      else if (key === "className") el.className = value;
      else if (value !== false && value !== null && value !== undefined) el.setAttribute(key, value === true ? "" : value);
    }
    for (const child of children.flat()) if (child !== null && child !== undefined && child !== false) el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    return el;
  }

  function openPlans(url) { request("ui/open-link", { url }).catch(() => {}); }

  function errorView() {
    const e = state.error; if (!e) return null;
    return h("div", { className: "notice error" }, e.message || "Something went wrong.",
      e.plan_info_url ? h("span", {}, " ", h("a", { href: "#", onclick: (ev) => { ev.preventDefault(); openPlans(e.plan_info_url); } }, "See plans")) : null);
  }

  function accountView() {
    const a = state.account; if (!a) return null;
    if (!a.cloud_included) {
      return h("div", { className: "notice" }, "The " + (a.plan || "current") + " plan" + (a.team ? " for " + a.team : "") + " does not include Cloud machines. ",
        h("a", { href: "#", onclick: (ev) => { ev.preventDefault(); openPlans(a.plan_info_url); } }, "See plans"));
    }
    return h("div", { className: "muted" }, (a.team ? a.team + " · " : "") + (a.plan || "") + " plan · " + (a.active_machines || 0) + " of " + a.machine_limit + " machines active");
  }

  function machineRow(m) {
    const running = m.status === "running";
    const paused = m.status === "paused";
    return h("div", { className: "card machine" },
      h("div", { style: "min-width:0" },
        h("div", { className: "name" }, m.name || m.id),
        h("div", { className: "row muted" }, h("span", { className: "pill " + m.status }, m.status), h("span", {}, m.id))),
      h("div", { className: "row" },
        h("button", { onclick: () => navigate("/machines/" + encodeURIComponent(m.id)) }, "Open"),
        running ? h("button", { disabled: state.busy, onclick: () => machineAction("pause_machine", m.id) }, "Pause") : null,
        paused ? h("button", { disabled: state.busy, onclick: () => machineAction("resume_machine", m.id) }, "Resume") : null,
        state.confirmDelete === m.id
          ? h("button", { className: "danger", disabled: state.busy, onclick: () => { state.confirmDelete = null; machineAction("delete_machine", m.id); } }, "Delete everything on it")
          : h("button", { className: "danger", disabled: state.busy, onclick: () => { state.confirmDelete = m.id; render(); } }, "Delete")));
  }

  async function machineAction(tool, machineId) {
    const result = await callTool(tool, { machine_id: machineId });
    if (!result) return;
    if (tool === "delete_machine") { state.machines = state.machines.filter((m) => m.id !== machineId); if (parseRoute(state.route).machineId === machineId) navigate("/"); }
    else if (result.structuredContent && result.structuredContent.machine) upsertMachine(result.structuredContent.machine);
    render();
  }

  function createForm() {
    const a = state.account;
    if (a && !a.cloud_included) return null;
    const sizes = a && a.sizes_gb && a.sizes_gb.length ? a.sizes_gb : [4, 8, 16, 32];
    const name = h("input", { placeholder: "Name (optional)", maxlength: "64" });
    const size = h("select", {}, sizes.map((gb) => h("option", { value: String(gb) }, gb + " GB")));
    return h("div", { className: "card row" }, name, size,
      h("button", { className: "primary", disabled: state.busy, onclick: async () => {
        const args = { size_gb: Number(size.value) };
        if (name.value.trim()) args.name = name.value.trim();
        const result = await callTool("create_machine", args);
        if (result) applyToolResult(result);
      } }, "New machine"));
  }

  function homeView() {
    return [
      h("div", { className: "row spread" }, h("h1", {}, "cmux Cloud"), h("button", { disabled: state.busy, onclick: refresh }, "Refresh")),
      accountView(), errorView(),
      h("h2", {}, "Machines"),
      state.machines.length ? h("div", { className: "list" }, state.machines.map(machineRow)) : h("p", { className: "muted" }, state.busy ? "Loading…" : "No machines yet."),
      createForm(),
    ];
  }

  function machineView(machineId) {
    const m = state.machines.find((x) => x.id === machineId) || { id: machineId, name: null, status: "unknown" };
    const agent = h("select", {}, ["codex", "claude", "opencode", "pi"].map((a) => h("option", { value: a }, a)));
    const prompt = h("textarea", { placeholder: "What should the agent do on this machine?" });
    return [
      h("div", { className: "row spread" }, h("button", { onclick: () => navigate("/") }, "← Machines"), h("span", { className: "pill " + m.status }, m.status)),
      h("h1", { style: "margin-top:12px" }, m.name || m.id), errorView(),
      h("h2", {}, "Run an agent"),
      h("div", { className: "card list" }, prompt, h("div", { className: "row" }, agent,
        h("button", { className: "primary", disabled: state.busy, onclick: async () => {
          if (!prompt.value.trim()) return;
          const result = await callTool("run_agent", { machine_id: machineId, agent: agent.value, prompt: prompt.value.trim() });
          if (result) applyToolResult(result);
        } }, "Start"))),
      h("h2", {}, "Terminals"),
      state.terminals === null ? h("p", { className: "muted" }, "Loading…")
        : state.terminals.length ? h("div", { className: "list" }, state.terminals.map((t) => h("div", { className: "card machine" },
            h("div", { style: "min-width:0" }, h("div", { className: "name" }, t.title || t.id), h("div", { className: "muted" }, (t.running ? "running" : "exited") + (t.cwd ? " · " + t.cwd : ""))),
            h("button", { onclick: () => navigate("/machines/" + encodeURIComponent(machineId) + "/terminals/" + encodeURIComponent(t.id)) }, "View"))))
        : h("p", { className: "muted" }, "No terminals."),
    ];
  }

  function terminalView(machineId, terminalId) {
    const t = state.terminal || { text: "" };
    const input = h("input", { placeholder: "Type into the terminal", style: "flex:1" });
    const sendInput = async (submit) => {
      if (!input.value) return;
      const result = await callTool("send_input", { machine_id: machineId, terminal_id: terminalId, text: input.value, submit });
      if (result) { input.value = ""; readTerminal(); }
    };
    return [
      h("div", { className: "row spread" }, h("button", { onclick: () => navigate("/machines/" + encodeURIComponent(machineId)) }, "← Machine"),
        h("div", { className: "row" },
          h("button", { onclick: readTerminal }, "Refresh"),
          h("button", { onclick: () => request("ui/request-display-mode", { mode: "fullscreen" }).catch(() => {}) }, "Expand"),
          h("button", { onclick: () => request("ui/message", { role: "user", content: { type: "text", text: "Look at terminal " + terminalId + " on my cmux machine " + machineId + " and tell me what is happening." } }).catch(() => {}) }, "Ask about this"))),
      errorView(),
      h("pre", { className: "term", style: "margin-top:12px" }, t.text || "…"),
      h("div", { className: "row", style: "margin-top:8px" }, input,
        h("button", { onclick: () => sendInput(false) }, "Type"),
        h("button", { className: "primary", onclick: () => sendInput(true) }, "Send ⏎")),
    ];
  }

  function render() {
    const route = parseRoute(state.route);
    const view = route.terminalId ? terminalView(route.machineId, route.terminalId) : route.machineId ? machineView(route.machineId) : homeView();
    const focused = document.activeElement && document.activeElement.tagName;
    if (focused === "INPUT" || focused === "TEXTAREA" || focused === "SELECT") {
      // Keep what the user is typing: only refresh the terminal text in place.
      const pre = root.querySelector("pre.term");
      if (pre && state.terminal) pre.textContent = state.terminal.text || "…";
      return;
    }
    root.replaceChildren(h("main", {}, view));
  }

  new ResizeObserver(() => notify("ui/notifications/size-changed", { height: Math.ceil(document.documentElement.scrollHeight) })).observe(document.documentElement);

  request("ui/initialize", {
    protocolVersion: "2026-01-26",
    appInfo: { name: "cmux-cloud", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
  }).then((result) => {
    notify("ui/notifications/initialized", {});
    applyHostContext((result && result.hostContext) || {});
    const toolName = result && result.hostContext && result.hostContext.toolInfo && result.hostContext.toolInfo.tool && result.hostContext.toolInfo.tool.name;
    // A view the host opened without a tool call has no result coming; load it.
    if (!toolName) refresh();
    render();
  }).catch(() => render());
  render();
})();
`;

function appHtml(): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>cmux Cloud</title><style>${APP_STYLE}</style></head><body><div id="root"></div><script>${APP_SCRIPT}</script></body></html>`;
}

const RESOURCE_META = {
  ui: {
    csp: { connectDomains: [], resourceDomains: [] },
    prefersBorder: true,
  },
  "openai/ui": { availableDisplayModes: ["inline", "fullscreen"] },
  "openai/widgetDescription": "Shows the user's cmux Cloud machines, lets them create, pause, resume and delete machines, start coding agents, and watch agent terminals.",
  "openai/widgetPrefersBorder": true,
  "openai/widgetCSP": { connect_domains: [], resource_domains: [] },
};

let cached: { listing: Record<string, unknown>; content: Record<string, unknown> } | null = null;

export function cloudMcpAppResource() {
  cached ??= {
    listing: {
      uri: CLOUD_MCP_APP_URI,
      name: "cmux Cloud",
      description: "Machines, agents and terminals in cmux Cloud.",
      mimeType: "text/html;profile=mcp-app",
      _meta: RESOURCE_META,
    },
    content: {
      uri: CLOUD_MCP_APP_URI,
      mimeType: "text/html;profile=mcp-app",
      text: appHtml(),
      _meta: RESOURCE_META,
    },
  };
  return cached;
}
