// l10n-allow-file: test fixture replies, not shipped UI.
// Session Info keeps the rows its gallery reads while the gallery holds the same items
// (useSessionInfoLists `galleryRows`, keyed on the gallery's items, not their count). An image or a
// render replaced in place, with the gallery still one item, shows the new one (review of cmux#37907
// at 6c29ca42, P1); a streamed reply that changes nothing in the gallery renders no section.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { acpmuxPerf } from "../src/agent-session/acpmux/perf";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/useSessionInfo";
import { resetSessionInfoState, setSessionInfoOpen } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { activity, assistant, chat, summary, tool, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  setHeaderState({ inspector: true });
  setChatDisplay({});
  Object.defineProperty(dom.window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value() {} });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    StorageEvent: dom.window.StorageEvent,
    addEventListener: dom.window.addEventListener.bind(dom.window),
    removeEventListener: dom.window.removeEventListener.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  acpmuxPerf.enabled = false;
  acpmuxPerf.resetRenders();
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  setHeaderState({ inspector: false });
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function Pane({ snapshot }: { snapshot: AcpmuxSnapshot }) {
  const [shell, setShell] = useState<HTMLElement | null>(null);
  const sessionInfo = useSessionInfo({ snapshot, machineName: "Studio", shell });
  return (
    <section
      className="acpmux-shell"
      ref={(element) => {
        if (element && element !== shell) setShell(element);
      }}
    >
      <header className="acpmux-header">
        <ChatHeaderTools
          onTerminal={() => undefined}
          onBrowser={() => undefined}
          summary={null}
          menu={() => []}
          sessionInfo={sessionInfo.button}
        />
      </header>
      {sessionInfo.panel}
    </section>
  );
}

const FIRST = "data:image/png;base64,QUFBQQ==";
const SECOND = "data:image/png;base64,QkJCQg==";
const imageRow = assistant(`Here is the screenshot.\n\n![shot](${FIRST})`, 2, { id: "reply" });
const withRows = (rows: AcpmuxRow[], fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot => ({
  ...chat(rows),
  sessionId: "chat-a",
  ...fields,
});

const galleryImages = (container: HTMLElement) =>
  [...container.ownerDocument.querySelectorAll<HTMLImageElement>(".acpmux-chat-gallery-image img")].map((image) =>
    image.getAttribute("src"),
  );
const galleryTitles = (container: HTMLElement) =>
  [...container.ownerDocument.querySelectorAll(".acpmux-chat-gallery-tile.is-render .acpmux-chat-gallery-title")].map(
    (title) => title.textContent,
  );

async function mount(container: HTMLElement, snapshot: AcpmuxSnapshot) {
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={snapshot} />);
  });
  await act(async () => setSessionInfoOpen(true));
}

async function openGallery(container: HTMLElement) {
  const row = [...container.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row--button")].find(
    (button) => button.querySelector(".acpmux-session-info-row__end")?.textContent === "1",
  );
  expect(row).toBeDefined();
  await act(async () => row!.click());
}

const renderTool = (title: string, html: string) =>
  activity(
    [
      tool("mcp__cmux__render", "other", "completed", {
        id: "render-call",
        inputSummary: JSON.stringify({ html, title }),
      }),
    ],
    3,
    { id: "render-row" },
  );
const renderRows = (title: string, html: string): AcpmuxRow[] => [
  user("Draw it", 4, { id: "prompt" }),
  renderTool(title, html),
  summary(2, { id: "summary" }),
];

test("an image replaced in place, the gallery still one image, shows the new image", async () => {
  const container = installDom();
  await mount(container, withRows([imageRow]));
  await openGallery(container);
  expect(galleryImages(container)).toEqual([FIRST]);
  const replaced = { ...imageRow, version: 2, text: `Here is the screenshot.\n\n![shot](${SECOND})` };
  await act(async () => root!.render(<Pane snapshot={withRows([replaced])} />));
  expect(galleryImages(container)).toEqual([SECOND]);
});

test("a render replaced in place, the gallery still one render, shows the new render", async () => {
  const container = installDom();
  await mount(container, withRows(renderRows("First page", "<p>one</p>")));
  await openGallery(container);
  expect(galleryTitles(container)).toEqual(["First page"]);
  await act(async () => root!.render(<Pane snapshot={withRows(renderRows("Second page", "<p>two</p>"))} />));
  expect(galleryTitles(container)).toEqual(["Second page"]);
});

test("a streamed reply that changes nothing in the gallery renders no Session Info section", async () => {
  const container = installDom();
  const streaming = (text: string) => assistant(text, 1, { id: "streaming" });
  const live = { isWorking: true };
  await mount(container, withRows([imageRow, streaming("Looking")], live));
  await openGallery(container);
  expect(galleryImages(container)).toEqual([FIRST]);
  acpmuxPerf.enabled = true;
  acpmuxPerf.resetRenders();
  for (const text of ["Looking at", "Looking at the", "Looking at the page"])
    await act(async () => root!.render(<Pane snapshot={withRows([imageRow, streaming(text)], live)} />));
  expect(acpmuxPerf.renders.get("session-info:sections") ?? 0).toBe(0);
  expect(acpmuxPerf.renders.get("session-info:panel") ?? 0).toBe(0);
  expect(galleryImages(container)).toEqual([FIRST]);
});
