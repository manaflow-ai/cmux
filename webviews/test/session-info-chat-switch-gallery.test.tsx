// l10n-allow-file: test fixture replies, not shipped UI.
// Session Info keeps the rows its gallery reads while nothing it shows changed (useSessionInfoLists
// `galleryRows`), and the panel outlives a chat switch. Another chat's rows are always new: with the
// same image count, output files and tool calls in both, switching from chat A to chat B shows B's
// images in the gallery, never A's (review of cmux#37907 at 7fa9cfd9, F2).
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { setChatDisplay } from "../src/agent-session/acpmux/chatDisplay";
import { ChatHeaderTools } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { setHeaderState } from "../src/agent-session/acpmux/header/headerState";
import { useSessionInfo } from "../src/agent-session/acpmux/session-info/useSessionInfo";
import { resetSessionInfoState, setSessionInfoOpen } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { assistant, chat } from "../src/gallery/fixtures/acpmux";
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

const A_IMAGE = "data:image/png;base64,QUFBQQ==";
const B_IMAGE = "data:image/png;base64,QkJCQg==";
const withImage = (sessionId: string, src: string): AcpmuxSnapshot => {
  const snapshot = chat([assistant(`Here is the screenshot.\n\n![shot](${src})`, 2)]);
  return { ...snapshot, sessionId, summary: snapshot.summary && { ...snapshot.summary, sessionId } };
};

const galleryImages = (container: HTMLElement) =>
  [...container.ownerDocument.querySelectorAll<HTMLImageElement>(".acpmux-chat-gallery-image img")].map((image) =>
    image.getAttribute("src"),
  );

test("switching chats shows the new chat's images in Session Info's gallery, never the old chat's", async () => {
  const container = installDom();
  const a = withImage("chat-a", A_IMAGE);
  const b = withImage("chat-b", B_IMAGE);
  const openGallery = async () => {
    const row = [...container.querySelectorAll<HTMLButtonElement>("button.acpmux-session-info-row--button")].find(
      (button) => button.querySelector(".acpmux-session-info-row__end")?.textContent === "1",
    );
    expect(row).toBeDefined();
    await act(async () => row!.click());
  };
  // Session Info open on both chats (each keeps its own open state, sessionInfoState.ts), so the
  // switch keeps the panel drawn and the image count (1) the same.
  await act(async () => {
    root = createRoot(container);
    root.render(<Pane snapshot={b} />);
  });
  await act(async () => setSessionInfoOpen(true));
  await act(async () => root!.render(<Pane snapshot={a} />));
  await act(async () => setSessionInfoOpen(true));
  await openGallery();
  expect(galleryImages(container)).toEqual([A_IMAGE]);
  await act(async () => root!.render(<Pane snapshot={b} />));
  if (galleryImages(container).length === 0) await openGallery();
  expect(galleryImages(container)).toEqual([B_IMAGE]);
});
