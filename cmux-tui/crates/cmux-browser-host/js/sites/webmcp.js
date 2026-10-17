// sites.webmcp: tools a page declares for agents through WebMCP
// (navigator.modelContext, webmachinelearning.github.io/webmcp). WebKit has
// no native WebMCP yet, so this finds tools a page registers with a WebMCP
// implementation it ships itself (such as the MCP-B polyfill), or its
// document.modelContext. The page writes its tools' annotations, so
// readOnlyHint is advisory: every call is a confirmed draft, since it can
// change data or send it, unless the agent passes { trustReadOnlyHint: true }
// for that call to a tool that declares readOnlyHint.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;

  // Runs in the page world. arg: { op: "list" } or { op: "call", name, input }.
  async function webmcp(arg) {
    const mc = (navigator && navigator.modelContext) || document.modelContext || null;
    if (!mc) return { supported: false };
    const norm = (t) => ({ name: t.name, title: t.title || null, description: t.description || "", inputSchema: typeof t.inputSchema === "string" ? JSON.parse(t.inputSchema) : t.inputSchema || null, annotations: t.annotations || {} });
    let tools = null;
    if (typeof mc.listTools === "function") tools = await mc.listTools();
    else if (typeof mc.codexGetTools === "function") tools = await mc.codexGetTools();
    else if (mc.tools) tools = mc.tools instanceof Map ? [...mc.tools.values()] : Array.isArray(mc.tools) ? mc.tools : Object.values(mc.tools);
    if (!tools) return { supported: true, listable: false };
    tools = (Array.isArray(tools) ? tools : tools.tools || []).map(norm);
    if (arg.op === "list") return { supported: true, listable: true, tools };
    const tool = tools.find((t) => t.name === arg.name);
    if (!tool) return { supported: true, listable: true, missing: true, tools: tools.map((t) => t.name) };
    let result;
    if (typeof mc.executeTool === "function") result = await mc.executeTool(arg.name, arg.input);
    else if (typeof mc.callTool === "function") result = await mc.callTool({ name: arg.name, arguments: arg.input });
    else if (typeof mc.codexExecuteTool === "function") result = JSON.parse(await mc.codexExecuteTool({ name: arg.name }, JSON.stringify(arg.input)));
    else {
      const raw = (mc.tools instanceof Map ? mc.tools.get(arg.name) : (Array.isArray(mc.tools) ? mc.tools : Object.values(mc.tools || {})).find((t) => t.name === arg.name)) || null;
      if (!raw || typeof raw.execute !== "function") return { supported: true, listable: true, notCallable: true };
      result = await raw.execute(arg.input, { requestUserInteraction: async () => { throw new Error("user interaction is not available to agents"); } });
    }
    return { supported: true, result: JSON.parse(JSON.stringify(result === undefined ? null : result)) };
  }

  S.register(
    "webmcp",
    (t) => {
      const UNSUPPORTED = "webmcp: this page declares no WebMCP tools (no navigator.modelContext). WebKit has no built-in WebMCP; only pages that ship their own implementation expose tools.";
      async function list(page) {
        const r = await (page || t.currentPage()).evaluate(webmcp, { op: "list" });
        if (!r.supported) return { supported: false, tools: [], note: UNSUPPORTED };
        if (!r.listable) return { supported: true, tools: [], note: "webmcp: the page has navigator.modelContext but its implementation offers no way to list tools" };
        return { supported: true, tools: r.tools };
      }
      async function run(page, name, input) {
        const r = await page.evaluate(webmcp, { op: "call", name, input: input === undefined ? {} : input });
        if (!r.supported) throw new S.SiteError("unsupported", UNSUPPORTED);
        if (r.missing) throw new S.SiteError("not_found", `webmcp.call: the page has no tool ${JSON.stringify(name)}; tools: ${r.tools.join(", ")}`);
        if (r.notCallable) throw new S.SiteError("unsupported", `webmcp.call: tool ${JSON.stringify(name)} cannot be called from outside the page`);
        return r.result;
      }
      return {
        // { supported, tools: [{ name, title, description, inputSchema, annotations }] } for the current tab or `page`.
        tools: (page) => list(page),
        // Calls a tool: returns a draft that call(draftId, { confirm: true })
        // runs. Options: { page, trustReadOnlyHint }. With trustReadOnlyHint:
        // true, a tool that declares readOnlyHint runs now; the agent takes
        // the page's word for that one call.
        async call(name, input, options = {}) {
          if (typeof name === "string" && /^draft-\d+-[0-9a-f]+$/.test(name)) return t.write("webmcp", "call", name, input);
          const page = options.page || t.currentPage();
          const { tools } = await list(page);
          const tool = tools.find((x) => x.name === name);
          if (!tool) throw new S.SiteError("not_found", `webmcp.call: the page has no tool ${JSON.stringify(name)}; tools: ${tools.map((x) => x.name).join(", ") || "none"}`);
          if (options.trustReadOnlyHint === true && tool.annotations && tool.annotations.readOnlyHint === true) return run(page, name, input);
          const url = page.url();
          return t.write("webmcp", "call", { name, input }, undefined, () => ({
            category: "[9]/[14] a page tool that may change or send data",
            summary: `Call WebMCP tool "${name}" on ${url.split("?")[0]}`,
            preview: { page: url, tool: name, description: tool.description, input: input === undefined ? {} : input },
            // The confirmed call sends the previewed (frozen) input.
            run: async (preview) => {
              if (page.url() !== url) throw new S.SiteError("page_changed", `webmcp.call: the tab navigated away from ${url}; nothing was called`);
              return run(page, preview.tool, preview.input);
            },
          }));
        },
      };
    },
    { summary: "List and call tools a page declares through WebMCP (calls are confirmed drafts)" },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
