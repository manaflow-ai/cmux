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
        return Promise.resolve({ ok: true, value: { guiMode: context } });
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
      if (document.querySelector(".gui-mode-title")?.textContent === context.copy.homeTitle) finish();
    }
    observer.observe(document, { childList: true, subtree: true, characterData: true });
    check();
  });
  process.stdout.write(JSON.stringify({
    errors, requests,
    title: document.querySelector(".gui-mode-title")?.textContent,
    hasEditor: !!document.querySelector(".gui-mode-editor [contenteditable=true]"),
    selectedProvider: document.querySelector(".gui-mode-agent-select")?.value,
    submitDisabled: document.querySelector(".gui-mode-submit")?.disabled,
  }));
} finally {
  dom.window.close();
}
