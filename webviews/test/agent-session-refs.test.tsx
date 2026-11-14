// Agent session references in a reply (conversation/sessionRefs.ts, SessionRef.tsx). Leo,
// 2026-11-03: "these links aren't clickable... links like this be able to either open or go to
// these sessions inside a workspace if it's yours. only if it's yours/shared with you". An agent
// link in inline code is a link; clicking it opens the session's chat when the daemon resolves it
// (`_acpmux/resolve`) and its web page when not. A `HOST/NAME` the daemon resolves becomes the
// session chip and opens the chat the way a sender's name does (`openSender`); one it does not, and
// code that only looks like one (`src/app`, `3/4`), stays plain code. Each ref is asked once.
// The mock chat `mock-session-links` (mockFixture.ts) draws the same reply.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  MouseEvent: dom.window.MouseEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|FocusEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { renderInline } = await import("../src/agent-session/acpmux/conversation/inlineMarkdown");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");
const refs = await import("../src/agent-session/acpmux/conversation/sessionRefs");
const { mockResolvable, SESSION_LINK_REFS } = await import("../src/agent-session/acpmux/mockFixture");

const asked: string[] = [];
// The mock daemon's answers (mockFixture.ts `mockResolvable`): a session it lists, else not found.
const resolve = async (query: string) => {
  asked.push(query);
  const session = mockResolvable[query];
  if (!session) throw new Error("not found");
  return { session };
};

beforeEach(() => {
  asked.length = 0;
  refs.resetSessionRefs();
  refs.setSessionRefResolver(resolve);
});
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  refs.setSessionRefResolver(undefined);
});
afterAll(async () => {
  await teardownDom(saved, { scope });
});

/// One macrotask, inside act so React commits what it brought.
const tick = () => act(async () => void (await new Promise((done) => setTimeout(done, 0))));
/// Yields until `ready` holds (an answer came, the idle ask ran), then once more so it rendered.
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 5000 && !ready(); turn++) await tick();
  expect(ready()).toBe(true);
  await tick();
}
/// Every ref asked about has its answer.
const answered = () => asked.every((query) => refs.knownSessionRef(query) !== undefined);

async function draw(markdown: string, sessions: AcpmuxSessionEntry[] = []) {
  const store = new SubsessionStore();
  store.set(sessions);
  const opened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider
        value={{ store, open: () => undefined, openSender: (sessionId) => void opened.push(sessionId) }}
      >
        <p>{renderInline(markdown)}</p>
      </SubsessionContext.Provider>,
    ),
  );
  return opened;
}

const click = (element: Element) => {
  const event = new dom.window.MouseEvent("click", { bubbles: true, cancelable: true });
  element.dispatchEvent(event);
  return event;
};
async function hover(element: Element) {
  await act(async () => {
    element.dispatchEvent(new dom.window.PointerEvent("pointerover", { bubbles: true }));
    element.dispatchEvent(new dom.window.PointerEvent("pointerenter", { bubbles: false }));
  });
  await until(answered);
}
const linkTo = (href: string) => [...host.querySelectorAll("a")].find((a) => a.getAttribute("href") === href);

test("an agent link in inline code is a link that opens the reader's own session", async () => {
  const opened = await draw(`- \`${SESSION_LINK_REFS.swarm}\``);
  const link = linkTo(SESSION_LINK_REFS.swarm)!;
  expect(link).toBeDefined();
  expect(link.querySelector("code")?.textContent).toBe(SESSION_LINK_REFS.swarm);
  await hover(link);
  // A link that names only host and session is resolved by the session's id.
  expect(asked).toEqual(["01a19ee7-0000-7de2-862f-0b255ab41dd0"]);
  const event = click(link);
  expect(event.defaultPrevented).toBe(true);
  expect(opened).toEqual(["mock-zsh"]);
  // Asked once, however often it is pointed at or clicked.
  await hover(link);
  click(link);
  expect(asked).toHaveLength(1);
});

test("a click before any hover asks, then opens the chat", async () => {
  const opened = await draw(`\`${SESSION_LINK_REFS.lane}\``);
  const event = click(linkTo(SESSION_LINK_REFS.lane)!);
  expect(event.defaultPrevented).toBe(true);
  await until(() => opened.length > 0);
  expect(opened).toEqual(["mock-ghostty-config"]);
});

test("an agent link to a session that is not the reader's opens its web page", async () => {
  const opened = await draw(`\`${SESSION_LINK_REFS.notYours}\``);
  const link = linkTo(SESSION_LINK_REFS.notYours)!;
  expect(link).toBeDefined();
  await hover(link);
  // A link with its harness goes to acpmux whole.
  expect(asked).toEqual([SESSION_LINK_REFS.notYours]);
  const event = click(link);
  expect(event.defaultPrevented).toBe(false);
  expect(opened).toEqual([]);

  // Clicked before the answer came: the link is followed once it came (a second, unprevented click).
  refs.resetSessionRefs();
  let followed = 0;
  // Read after the page's own handler (React's, at the root) had its say.
  const count = (e: Event) => void (!e.defaultPrevented && followed++);
  dom.window.document.addEventListener("click", count);
  expect(click(link).defaultPrevented).toBe(true);
  await until(() => followed > 0);
  dom.window.document.removeEventListener("click", count);
  expect(followed).toBe(1);
  expect(opened).toEqual([]);
});

test("a HOST/NAME the daemon resolves becomes the session chip and opens the chat", async () => {
  const opened = await draw(`- \`${SESSION_LINK_REFS.name}\``);
  // Plain code until the answer comes, asked once the page is idle.
  expect(host.querySelector("button")).toBeNull();
  await until(() => host.querySelector("button.cv-session-ref") !== null);
  const chip = host.querySelector<HTMLButtonElement>("button.cv-session-ref")!;
  expect(chip).not.toBeNull();
  expect(chip.textContent).toBe(SESSION_LINK_REFS.name);
  act(() => void click(chip));
  expect(opened).toEqual(["mock-notice-mid-reply"]);
  expect(asked).toEqual([SESSION_LINK_REFS.name]);
});

test("a HOST/NAME the session list names is a chip at once, with no ask", async () => {
  const opened = await draw("`gcp-agent-lane-3/chief-ui`", [
    {
      sessionId: "mux-chief-ui",
      name: "gcp-agent-lane-3/chief-ui",
      peer: "gcp-agent-lane-3",
      displayTitle: "",
      pendingPermissions: 0,
    } as AcpmuxSessionEntry,
  ]);
  const chip = host.querySelector("button.cv-session-ref")!;
  expect(chip).not.toBeNull();
  act(() => void click(chip));
  expect(opened).toEqual(["mux-chief-ui"]);
  // The idle ask a name would make has had its turn: none was made.
  await until(() => refs.knownSessionRef("gcp-agent-lane-3/chief-ui") === undefined);
  await tick();
  expect(asked).toEqual([]);
});

test("code that only looks like a/b stays plain code unless it is a session", async () => {
  await draw(`\`${SESSION_LINK_REFS.unknown}\` \`${SESSION_LINK_REFS.path}\` \`3/4\` \`src/app.ts\` \`and/or\``);
  await until(() => asked.length === 3 && answered());
  expect(host.querySelector("a, button")).toBeNull();
  expect([...host.querySelectorAll("code")].map((code) => code.textContent)).toEqual([
    SESSION_LINK_REFS.unknown,
    SESSION_LINK_REFS.path,
    "3/4",
    "src/app.ts",
    "and/or",
  ]);
  // A fraction and a file are never asked about.
  expect(asked.sort()).toEqual(["and/or", SESSION_LINK_REFS.unknown, SESSION_LINK_REFS.path].sort());
});

test("without a daemon an agent link is a plain web link and a name plain code", async () => {
  refs.setSessionRefResolver(undefined);
  const opened = await draw(`\`${SESSION_LINK_REFS.swarm}\` \`${SESSION_LINK_REFS.name}\``);
  await tick();
  const link = linkTo(SESSION_LINK_REFS.swarm)!;
  expect(link).toBeDefined();
  expect(click(link).defaultPrevented).toBe(false);
  expect(host.querySelector("button")).toBeNull();
  expect(opened).toEqual([]);
});

test("agentRef reads every agent link form and no file or fraction", () => {
  // An opaque link goes to acpmux whole: it resolves one only where it holds the key.
  expect(refs.agentRef("https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123")).toEqual({
    kind: "link",
    href: "https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123",
    query: "https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123",
  });
  expect(refs.agentRef("https://cmux.com/deeplink/agent?id=aid-0123")).toEqual({
    kind: "link",
    href: "https://cmux.com/deeplink/agent?id=aid-0123",
  });
  expect(refs.agentRef("cmux://agent/codex/019a-thread?host=build-mac")).toMatchObject({
    kind: "link",
    query: "cmux://agent/codex/019a-thread?host=build-mac",
  });
  expect(refs.agentRef("https://example.com/deeplink/agent?session=x")).toBeUndefined();
  expect(refs.agentRef("10/31")).toBeUndefined();
  expect(refs.agentRef("docs/notes.md")).toBeUndefined();
  expect(refs.agentRef("a/b/c")).toBeUndefined();
});
