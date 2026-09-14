import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";

const context = JSON.parse(readFileSync(0, "utf8"));
const errors = [];
const requests = [];
const virtualConsole = new VirtualConsole();
virtualConsole.on("jsdomError", error => errors.push(error.message));
const dom = await JSDOM.fromFile(process.argv[2], {
  resources: "usable", runScripts: "dangerously", pretendToBeVisual: true, virtualConsole,
  beforeParse(window) {
    // JSDOM has no viewport scrolling; the real browser supplies this API.
    window.scrollTo = () => {};
    window.webkit = { messageHandlers: { agentSession: {
      postMessage(request) {
        requests.push(request.method);
        if (request.method === "app.context") {
          return Promise.resolve({ ok: true, value: {
            panelId: "panel-1",
            workspaceId: "workspace-1",
            renderer: "guiMode",
            initialProviderId: "codex",
            workingDirectory: "/tmp/cmux",
            copy: context.copy,
            theme: {
              isDark: true,
              pageBackground: "transparent",
              surfaceBackground: "rgba(0, 0, 0, 0.3)",
              surfaceElevatedBackground: "rgba(0, 0, 0, 0.4)",
              inputBackground: "rgba(0, 0, 0, 0.2)",
              border: "rgba(255, 255, 255, 0.1)",
              borderStrong: "rgba(255, 255, 255, 0.2)",
              text: "#fff",
              mutedText: "#aaa",
              softText: "#ddd",
              accent: "#8ab4f8",
              accentSoft: "rgba(138, 180, 248, 0.2)",
              danger: "#ff8d7e",
              shadow: "rgba(0, 0, 0, 0.2)",
            },
            guiMode: context,
          } });
        }
        if (request.method === "provider.list") {
          return Promise.resolve({ ok: true, value: [{
            id: "codex",
            displayName: "Codex",
            executableName: "codex",
            transportKind: "stdio-jsonrpc",
            arguments: ["app-server", "--listen", "stdio://"],
            autoStart: false,
          }] });
        }
        return Promise.resolve({ ok: true, value: {} });
      },
    } } };
  },
});
try {
  const document = dom.window.document;
  await new Promise(resolve => {
    const observer = new dom.window.MutationObserver(check);
    const deadline = setTimeout(finish, 3000);
    function finish() { clearTimeout(deadline); observer.disconnect(); resolve(); }
    function check() {
      if (document.querySelector(".gui-mode-agent-shell")) finish();
    }
    observer.observe(document, { childList: true, subtree: true, characterData: true });
    check();
  });
  process.stdout.write(JSON.stringify({
    errors, requests,
    home: !!document.querySelector(".gui-mode-welcome"),
    composerVisible: !!document.querySelector(".gui-mode-agent-shell"),
    hasEditor: !!document.querySelector(".gui-mode-agent-shell [contenteditable=true]"),
    submitDisabled: document.querySelector(".send-button")?.disabled,
  }));
} finally {
  dom.window.close();
}
