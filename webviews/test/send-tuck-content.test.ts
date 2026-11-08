// A prompt sent while scrolled up tucks behind the composer (conversation/sendTuck.ts). Its copy is
// taken at the send: a send the host takes only later (a new chat, a held prompt) clears the composer
// then, and by then the reader may have typed or attached the next draft, which must not be what
// tucks away. Review of #38217, F2.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
beforeAll(() => {
  dom = new JSDOM(`<!doctype html><div class="acpmux-main"><form class="acpmux-composer">
    <div class="acpmux-attachment"><img src="data:image/png;base64,AAAA" alt=""></div>
    <div id="box"><div class="acpmux-composer-prompt"><div contenteditable="true">the prompt I sent</div></div></div>
  </form></div>`);
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the tuck's copy is the prompt as sent, not the draft the composer holds when it clears", async () => {
  const { tuckContent } = await import("../src/agent-session/acpmux/conversation/sendTuck");
  const document = dom.window.document;
  const box = document.getElementById("box")!;
  const copy = tuckContent(box, "the prompt I sent");
  // The reader starts the next draft before the host takes the first.
  document.querySelector(".acpmux-composer-prompt [contenteditable]")!.textContent = "my next draft";
  document.querySelector(".acpmux-attachment")!.remove();
  expect(copy?.textContent).toContain("the prompt I sent");
  expect(copy?.textContent).not.toContain("my next draft");
  expect(copy?.querySelectorAll("img").length, "its picture").toBe(1);
});
