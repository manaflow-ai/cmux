// A pasted cmux link draws as what it names (Leo, 2026-11-08: "when I paste the URL link, when I do
// the right-click copy link to workspace thing, it should be able to render in the box that it is
// an actual chat that is there, like with the title and whatever, and, like, to be potentially
// hoverable as well, instead of just being, like, you know, here's the raw URL"): the parser reads
// every link form (conversation/cmuxLinks.ts); a sent message and the draft draw a known link as a
// chip with its title, its text still the link; an id nothing names stays the link; a chat's chip
// opens the chat; a workspace's chip shows its card on hover.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { cmuxLinkTarget } from "../src/agent-session/acpmux/conversation/cmuxLinks";
import { PromptTyped } from "../src/agent-session/acpmux/conversation/PromptText";
import { setLinkPlaces } from "../src/agent-session/acpmux/chips/cmuxLinkPlaces";
import { setPageChats } from "../src/agent-session/acpmux/chips/cmuxLinkResolve";
import { SessionHoverStore } from "../src/agent-session/acpmux/started/sessionHover";
import { SessionHoverContext } from "../src/agent-session/acpmux/started/sessionHoverCardModel";
import { linkedText } from "../src/agent-session/acpmux/chips/linkedText";
import { deeplinks } from "../src/agent-session/acpmux/composer/deeplinks";
import { resetSessionRefs, setSessionRefResolver } from "../src/agent-session/acpmux/conversation/sessionRefs";
import { SubsessionContext, SubsessionStore } from "../src/agent-session/acpmux/subagents/subsessions";
import { openOfferChat, openSenderChat } from "../src/agent-session/acpmux/rows/rowActions";
import { chipSelectionText, selectionHtml } from "../src/agent-session/acpmux/conversation/selectionCopy";
import { htmlMarkdown } from "../src/agent-session/acpmux/richClipboard";
import { teardownDom } from "./support/domTeardown";

const HEX = "16c92e4354fcaf05540386720d78e251";
const WORKSPACE = `cmux-nightly://workspace/ws_${HEX}`;
const SESSION = "9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
const AGENT = `cmux://agent/claude/${SESSION}?host=studio&name=reviewer`;
const WEB_AGENT = `https://cmux.com/deeplink/agent?harness=claude&session=${SESSION}`;

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
  "MouseEvent",
  "FocusEvent",
  "CompositionEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    MouseEvent: window.MouseEvent,
    FocusEvent: window.FocusEvent,
    CompositionEvent: window.CompositionEvent,
  });
  const box = { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0 };
  Object.assign(window.Range.prototype, { getClientRects: () => [], getBoundingClientRect: () => box });
  host = window.document.getElementById("root")!;
});

beforeEach(() => {
  setLinkPlaces([]);
  setPageChats(undefined);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  setLinkPlaces([]);
  setPageChats(undefined);
  await teardownDom(saved, { window: dom.window, scope });
});

const place = (title: string, extra: Record<string, unknown> = {}) => ({
  id: `ws_${HEX}`,
  kind: "workspace",
  title,
  ...extra,
});

function chats(): SessionHoverStore {
  const store = new SessionHoverStore();
  store.set([
    {
      sessionId: "acp-reviewer",
      harness: "claude",
      agentSessionId: SESSION,
      title: "Review the retry fix",
      host: "build-box",
      hostKind: "cloud",
    } as AcpmuxSessionEntry,
  ]);
  return store;
}

async function mount(node: React.ReactNode) {
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () => root!.render(node));
}

// ---------------------------------------------------------------------------------------------
// The parser

test("the parser reads every cmux link form", () => {
  expect(cmuxLinkTarget(WORKSPACE)).toEqual({ kind: "workspace", id: `ws_${HEX}` });
  expect(cmuxLinkTarget(`cmux://workspace/ws_${HEX}?machine=machine_${HEX}`)).toEqual({
    kind: "workspace",
    id: `ws_${HEX}`,
    machine: `machine_${HEX}`,
  });
  expect(cmuxLinkTarget(`cmux-dev-mytag://pane/pane_${HEX}`)).toEqual({ kind: "pane", id: `pane_${HEX}` });
  expect(cmuxLinkTarget(`cmux://tab/tab_${HEX}`)).toEqual({ kind: "tab", id: `tab_${HEX}` });
  expect(cmuxLinkTarget("cmux://session/ses-01.example_a")).toEqual({ kind: "session", session: "ses-01.example_a" });
  expect(cmuxLinkTarget("cmux://session/ses-01#turn-turn_7")).toEqual({
    kind: "session",
    session: "ses-01",
    turn: "turn_7",
  });
  expect(cmuxLinkTarget("cmux://chief/0a1b2c3d/session/sub-1")).toEqual({
    kind: "chief",
    home: "0a1b2c3d",
    session: "sub-1",
  });
  expect(cmuxLinkTarget(AGENT)).toEqual({
    kind: "agent",
    harness: "claude",
    session: SESSION,
    host: "studio",
    name: "reviewer",
    web: false,
  });
  expect(cmuxLinkTarget(WEB_AGENT)).toEqual({ kind: "agent", harness: "claude", session: SESSION, web: true });
  expect(cmuxLinkTarget(`https://www.cmux.com/ja/deeplink/agent?host=host-1&session=${SESSION}`)).toEqual({
    kind: "agent",
    session: SESSION,
    host: "host-1",
    web: true,
  });
  expect(cmuxLinkTarget("https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123")).toEqual({
    kind: "agent",
    opaque: "aid-0123456789abcdef0123",
    web: true,
  });
  expect(cmuxLinkTarget(`cmux://group/grp_abcdefghij0123456789/workspace/ws_${HEX}`)).toEqual({
    kind: "group",
    id: "grp_abcdefghij0123456789",
    workspace: `ws_${HEX}`,
  });
  // A malformed hint is dropped, never the link.
  expect(cmuxLinkTarget(`cmux://agent/claude/${SESSION}?host=a%20b`)).toEqual({
    kind: "agent",
    harness: "claude",
    session: SESSION,
    web: false,
  });
});

test("the parser reads nothing else as a cmux link", () => {
  for (const text of [
    "cmux://workspace/ws_123",
    `cmux://workspace/pane_${HEX}`,
    `cmux://workspace/ws_${HEX.toUpperCase()}`,
    `cmux://workspace/ws_${HEX}/extra`,
    `javascript://workspace/ws_${HEX}`,
    `https://example.com/deeplink/agent?harness=claude&session=${SESSION}`,
    "https://cmux.com/deeplink/ssh?host=dev",
    "cmux://session/a b",
    "cmux://session/x#nope",
    "cmux://chief/xyz/session/a",
    "cmux:/workspace",
    "",
  ])
    expect(cmuxLinkTarget(text)).toBeUndefined();
});

// ---------------------------------------------------------------------------------------------
// A sent message

test("a sent message draws a known workspace link as a chip with its title, the link kept", () => {
  setLinkPlaces([place("Retry fix")]);
  const html = renderToStaticMarkup(
    <PromptTyped text={`In this chat, something was weird. ${WORKSPACE}`} show={(text) => text} />,
  );
  expect(html).toContain(`href="${WORKSPACE}"`);
  expect(html).toContain('data-cmux-link="workspace"');
  expect(html).toContain("Retry fix");
  expect(html).not.toContain("cv-link is-app");
});

test("a workspace on another machine names the machine after its title", () => {
  setLinkPlaces([place("Retry fix", { host: "studio" })]);
  const html = renderToStaticMarkup(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />);
  expect(html).toContain('<span class="cv-cmux-link__host">studio</span>');
});

test("an id nothing names stays the plain link", () => {
  setLinkPlaces([{ ...place("Other"), id: `ws_${"0".repeat(32)}` }]);
  const html = renderToStaticMarkup(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />);
  expect(html).toContain(`class="cv-link is-app" href="${WORKSPACE}"`);
  expect(html).not.toContain("data-cmux-link");
});

test("a rename redraws the chip with the new title; a close puts the link back", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />);
  expect(host.querySelector("[data-cmux-link=workspace]")?.textContent).toBe("Retry fix");
  await act(async () => setLinkPlaces([place("Retry fix, take two")]));
  expect(host.querySelector("[data-cmux-link=workspace]")?.textContent).toBe("Retry fix, take two");
  await act(async () => setLinkPlaces([]));
  expect(host.querySelector("[data-cmux-link]")).toBeNull();
  expect(host.querySelector("a.cv-link.is-app")?.getAttribute("href")).toBe(WORKSPACE);
});

test("a reply's bare cmux link draws as the same chip", () => {
  setLinkPlaces([place("Retry fix")]);
  const html = renderToStaticMarkup(<>{linkedText(`The fix is in ${WORKSPACE}.`, "k")}</>);
  expect(html).toContain('data-cmux-link="workspace"');
  expect(html).toContain("Retry fix");
});

// The host's push, in the shape the app sends it (CmuxNextAgentPane AgentPaneLinkPlaces, its event
// as AgentPaneLinkPlacesTests pins it): the page host's `linkPlaces` event, members it leaves out absent.
test("the app's linkPlaces push resolves a Copy Link to Workspace link to its chip", async () => {
  const { applyHostEvent } = await import("../src/agent-session/acpmux/pageHost");
  const tab = `tab_${"0123456789abcdef".repeat(2)}`;
  const sent = JSON.parse(
    JSON.stringify([
      { id: `ws_${HEX}`, kind: "workspace", title: "Research", host: "build-box" },
      { id: `pane_${"a".repeat(32)}`, kind: "pane", title: "zsh", host: "build-box", workspace: "Research" },
      { id: tab, kind: "tab", title: "zsh", host: "build-box", workspace: "Research" },
    ]),
  ) as unknown;
  applyHostEvent({ kind: "linkPlaces", value: sent });
  const html = renderToStaticMarkup(
    <PromptTyped
      text={`In this chat, something was weird. ${WORKSPACE} and cmux-nightly://tab/${tab}`}
      show={(text) => text}
    />,
  );
  expect(html).toContain(`href="${WORKSPACE}"`);
  expect(html).toContain('data-cmux-link="workspace"');
  expect(html).toContain("Research");
  expect(html).toContain('<span class="cv-cmux-link__host">build-box</span>');
  expect(html).toContain('data-cmux-link="tab"');
  // The next push is the whole list again: a workspace it no longer names is the link again.
  applyHostEvent({ kind: "linkPlaces", value: [] });
  expect(renderToStaticMarkup(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />)).not.toContain(
    "data-cmux-link",
  );
});

test("a chat link names its chat from the session list; its click is the plain link's, the host's", async () => {
  const store = chats();
  const opened: string[] = [];
  await mount(
    <SessionHoverContext.Provider value={{ store, open: (id) => opened.push(id) }}>
      <PromptTyped text={`Pick up ${AGENT} and ${WEB_AGENT}`} show={(text) => text} />
    </SessionHoverContext.Provider>,
  );
  const chips = [...host.querySelectorAll<HTMLAnchorElement>("[data-cmux-link=chat]")];
  expect(chips.map((chip) => chip.getAttribute("href"))).toEqual([AGENT, WEB_AGENT]);
  expect(chips[0]!.querySelector(".cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
  expect(chips[0]!.querySelector(".cv-cmux-link__host")?.textContent).toBe("build-box");
  let prevented = true;
  await act(async () => {
    const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
    chips[0]!.dispatchEvent(click);
    prevented = click.defaultPrevented;
  });
  expect(opened).toEqual([]);
  expect(prevented).toBe(false);
});

// ---------------------------------------------------------------------------------------------
// A chat chip's click is exactly its plain link's from before the chips (review of #38166, F1, F2):
// an app link (a session, a turn, a Chief chat, a native agent link with or without its message) is
// left to the host's link path, which opens any chat and reveals the turn or message; cmux.com's
// agent link opens as its URL chip did (`useAgentLinkClick`, `chat.offer.open` as a sender), a
// peer's the page does not list included.

const PEER = "4e8a2d6c-1b3f-4a5e-9c7d-0f1e2d3c4b5a";
const PEER_AGENT = `cmux://agent/codex/${PEER}?host=studio&name=peer`;
const PEER_WEB = `https://cmux.com/deeplink/agent?harness=codex&session=${PEER}`;

/// Mounts `node` as the app does: the session list's cards and the transcript's chat openers, with
/// the app's `chat.offer.open` recorded and acpmux answering `answers` (a query it has no answer
/// for names no chat of the reader's).
async function mountApp(node: React.ReactNode, answers: Record<string, Record<string, unknown>>) {
  const offers: Record<string, unknown>[] = [];
  const actions = window as unknown as { cmuxAcpmuxActions?: Record<string, (params: unknown) => Promise<unknown>> };
  actions.cmuxAcpmuxActions = {
    "chat.offer.open": async (params) => void offers.push(params as Record<string, unknown>),
  };
  const asked: string[] = [];
  const answered: Promise<unknown>[] = [];
  setSessionRefResolver((query) => {
    asked.push(query);
    const session = answers[query];
    const answer = session ? Promise.resolve({ session }) : Promise.reject(new Error("not found"));
    answered.push(answer.catch(() => undefined));
    return answer;
  });
  // The page is idle at once: acpmux is asked as soon as a chip mounts (sessionRefs.ts whenIdle).
  Object.assign(scope, {
    requestIdleCallback: (run: () => void) => {
      queueMicrotask(run);
      return 0;
    },
    cancelIdleCallback: () => undefined,
  });
  await mount(
    <SessionHoverContext.Provider value={{ store: chats(), open: openOfferChat }}>
      <SubsessionContext.Provider
        value={{ store: new SubsessionStore(), open: openOfferChat, openSender: openSenderChat }}
      >
        {node}
      </SubsessionContext.Provider>
    </SessionHoverContext.Provider>,
  );
  // Every answer acpmux gave is drawn.
  await act(async () => {
    await Promise.resolve();
    await Promise.all(answered);
  });
  return { offers, asked };
}

async function click(anchor: HTMLAnchorElement): Promise<boolean> {
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  await act(async () => {
    anchor.dispatchEvent(event);
    await Promise.resolve();
  });
  return event.defaultPrevented;
}

afterEach(() => {
  setSessionRefResolver(undefined);
  resetSessionRefs();
  delete (window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
  delete scope.requestIdleCallback;
  delete scope.cancelIdleCallback;
});

test("a peer's native agent link acpmux resolves names its chat and is left to the host's link path", async () => {
  const { offers } = await mountApp(<PromptTyped text={`Ask ${PEER_AGENT}`} show={(text) => text} />, {
    [PEER_AGENT]: { sessionId: "acp-peer", name: "Peer review", host: "studio" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.querySelector(".cv-cmux-link__title")?.textContent).toBe("Peer review");
  expect(chip.getAttribute("href")).toBe(PEER_AGENT);
  expect(chip.getAttribute("data-open-session")).toBeNull();
  expect(await click(chip)).toBe(false);
  expect(offers).toEqual([]);
});

test("a peer's cmux.com agent link acpmux resolves opens its chat the same way", async () => {
  const { offers } = await mountApp(<PromptTyped text={`Ask ${PEER_WEB}`} show={(text) => text} />, {
    [PEER_WEB]: { sessionId: "acp-peer", name: "Peer review", host: "studio" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.getAttribute("href")).toBe(PEER_WEB);
  expect(await click(chip)).toBe(true);
  expect(offers).toEqual([{ sessionId: "acp-peer", sender: true }]);
});

test("a reply's peer agent link is left to the host's link path the same way", async () => {
  const { offers } = await mountApp(<p>{linkedText(`Ask ${PEER_AGENT}`, "r")}</p>, {
    [PEER_AGENT]: { sessionId: "acp-peer", name: "Peer review" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(await click(chip)).toBe(false);
  expect(offers).toEqual([]);
});

test("a native agent link to one message keeps it: the click is the host's, which reveals the message", async () => {
  const link = `${PEER_AGENT}&message=m-0042`;
  const { offers } = await mountApp(<PromptTyped text={`Read ${link}`} show={(text) => text} />, {
    [link]: { sessionId: "acp-peer", name: "Peer review" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.getAttribute("href")).toBe(link);
  expect(await click(chip)).toBe(false);
  expect(offers).toEqual([]);
});

test("a listed chat's native agent link is the host's too, never a chat.offer.open", async () => {
  const { offers } = await mountApp(<PromptTyped text={`Ask ${AGENT}`} show={(text) => text} />, {});
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.querySelector(".cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
  expect(await click(chip)).toBe(false);
  expect(offers).toEqual([]);
});

test("a listed chat's agent link opens as the agent link did: the chat acpmux names, as a sender", async () => {
  const { offers } = await mountApp(<PromptTyped text={`Ask ${WEB_AGENT}`} show={(text) => text} />, {
    [WEB_AGENT]: { sessionId: "acp-reviewer" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.querySelector(".cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
  expect(await click(chip)).toBe(true);
  expect(offers).toEqual([{ sessionId: "acp-reviewer", sender: true }]);
});

test("an agent link that names no chat of the reader's stays the link and is followed", async () => {
  const { offers, asked } = await mountApp(<PromptTyped text={`Ask ${PEER_WEB}`} show={(text) => text} />, {});
  expect(asked).toEqual([PEER_WEB]);
  expect(host.querySelector("[data-cmux-link]")).toBeNull();
  const link = host.querySelector<HTMLAnchorElement>("a.cv-chip.is-web")!;
  expect(link.getAttribute("href")).toBe(PEER_WEB);
  expect(await click(link)).toBe(false);
  expect(offers).toEqual([]);
});

test("a listed session link, one to a turn and a Chief chat's all take the host's link path", async () => {
  // The listed chat is no chat this one started or sent: `chat.offer.open` would refuse it.
  const link = "cmux://session/acp-reviewer";
  const turn = `${link}#turn-t1`;
  const chief = "cmux://chief/0a1b2c3d/session/acp-reviewer";
  const { offers } = await mountApp(
    <PromptTyped text={`See ${link} and ${turn} and ${chief}`} show={(text) => text} />,
    {},
  );
  const chips = [...host.querySelectorAll<HTMLAnchorElement>("[data-cmux-link=chat]")];
  expect(chips.map((chip) => chip.getAttribute("href"))).toEqual([link, turn, chief]);
  for (const chip of chips) {
    expect(chip.getAttribute("data-open-session")).toBeNull();
    expect(await click(chip)).toBe(false);
  }
  expect(offers).toEqual([]);
});

test("a workspace chip in the app's page still takes the host's link path", async () => {
  setLinkPlaces([place("Retry fix")]);
  const { offers } = await mountApp(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />, {});
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=workspace]")!;
  expect(await click(chip)).toBe(false);
  expect(offers).toEqual([]);
});

test("a workspace chip's click is the anchor's own, the host's link path", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=workspace]")!;
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  // jsdom navigates nowhere for a custom scheme; what matters is that the page leaves it to the host.
  chip.addEventListener("click", (event) => event.preventDefault(), { once: true });
  let reachedHost = false;
  host.addEventListener("click", (event) => void (reachedHost = (event.target as Element).closest("a") === chip), {
    once: true,
  });
  chip.dispatchEvent(click);
  expect(chip.getAttribute("href")).toBe(WORKSPACE);
  expect(reachedHost).toBe(true);
});

test("hovering a workspace chip shows its card: the title, the kind and the link", async () => {
  setLinkPlaces([place("Retry fix", { host: "studio" })]);
  await mount(<PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=workspace]")!;
  expect(document.querySelector(".cv-cmux-link-card")).toBeNull();
  await act(async () => {
    chip.focus();
    chip.dispatchEvent(new window.FocusEvent("focus", { bubbles: false }));
    chip.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  });
  const card = document.querySelector(".cv-cmux-link-card");
  expect(card).not.toBeNull();
  expect(card!.querySelector(".cv-link-preview__site")?.textContent).toBe("Retry fix");
  expect(card!.querySelector(".cv-link-preview__target")?.textContent).toBe("Workspace on studio");
  expect(card!.querySelector(".cv-cmux-link-card__link")?.textContent).toBe(WORKSPACE);
});

test("a listed session chip's card opens as the chip does: it follows the link", async () => {
  const link = "cmux://session/acp-reviewer";
  const { offers } = await mountApp(<PromptTyped text={`See ${link}`} show={(text) => text} />, {});
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  const followed: string[] = [];
  host.addEventListener("click", (event) => {
    const anchor = (event.target as Element).closest("a");
    if (anchor) followed.push(anchor.getAttribute("href")!);
    event.preventDefault();
  });
  await act(async () => {
    chip.focus();
    chip.dispatchEvent(new window.FocusEvent("focus", { bubbles: false }));
    chip.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  });
  // The card opens after its hover delay: wait for it, not for a fixed time (check:fixed-waits).
  const deadline = Date.now() + 5000;
  while (!document.querySelector(".acpmux-session-hover") && Date.now() < deadline)
    await act(async () => {
      await new Promise((done) => setTimeout(done, 0));
    });
  const card = document.querySelector<HTMLElement>(".acpmux-session-hover");
  expect(card).not.toBeNull();
  await act(async () => card!.click());
  expect(followed).toEqual([link]);
  expect(offers).toEqual([]);
});

// ---------------------------------------------------------------------------------------------
// Copy: a chip copies as its link, as the plain link did (review of #38166, F3).

function selectAll(node: Node): Range {
  const range = document.createRange();
  range.selectNodeContents(node);
  return range;
}

test("a reply's selection copies a chip as its link, in its plain text and its HTML", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(
    <div className="cv-md">
      <p>{linkedText(`See ${WORKSPACE} now`, "r")}</p>
    </div>,
  );
  expect(host.querySelector("[data-cmux-link=workspace]")).not.toBeNull();
  const html = selectionHtml(selectAll(host.querySelector("p")!))!;
  expect(html).toContain(WORKSPACE);
  expect(html).not.toContain("Retry fix");
  expect(htmlMarkdown(html)).toBe(`See ${WORKSPACE} now`);
});

test("a prompt's selection copies its chips as their links", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(
    <SessionHoverContext.Provider value={{ store: chats(), open: () => undefined }}>
      <PromptTyped text={`See ${WORKSPACE} and ${AGENT}`} show={(text) => text} />
    </SessionHoverContext.Provider>,
  );
  expect(host.querySelectorAll("[data-cmux-link]").length).toBe(2);
  const range = selectAll(host);
  expect(selectionHtml(range)).toBeNull();
  expect(chipSelectionText(range)).toBe(`See ${WORKSPACE} and ${AGENT}`);
  // Nothing is left behind in the page.
  expect(document.body.lastElementChild?.getAttribute("aria-hidden")).not.toBe("true");
});

// A selection of a chip's title alone clones the title without its anchor: it still copies as the
// link (review of #38166, F3), in a reply's copy and in a prompt's.
test("a reply's selection of part of a chip's title copies its link", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(
    <div className="cv-md">
      <p>{linkedText(`See ${WORKSPACE} now`, "r")}</p>
    </div>,
  );
  const title = host.querySelector("[data-cmux-link=workspace] .cv-cmux-link__title")!.firstChild!;
  const range = document.createRange();
  range.setStart(title, 2);
  range.setEnd(title, 5);
  expect(htmlMarkdown(selectionHtml(range)!)).toBe(WORKSPACE);
  // From the text before it into its title: the text, then the whole link.
  const before = host.querySelector("p")!.firstChild!;
  range.setStart(before, 0);
  expect(htmlMarkdown(selectionHtml(range)!)).toBe(`See ${WORKSPACE}`);
});

test("a prompt's selection of a chip's title alone copies its link", async () => {
  setLinkPlaces([place("Retry fix")]);
  await mount(<PromptTyped text={`See ${WORKSPACE} now`} show={(text) => text} />);
  const title = host.querySelector("[data-cmux-link=workspace] .cv-cmux-link__title")!.firstChild!;
  const range = document.createRange();
  range.selectNodeContents(title);
  expect(selectionHtml(range)).toBeNull();
  expect(chipSelectionText(range)).toBe(WORKSPACE);
});

// An app link inside another URL is that URL's (review of #38166, F2): one link, the whole URL, as
// the page drew it before the chips; in a reply, a prompt and the draft's tokenizer alike.
const NESTED = "https://example.com/?next=cmux://session/s1";

test("an app link inside a web URL stays the web URL's, in a reply and a prompt", async () => {
  expect(deeplinks(`Open ${NESTED} now`)).toEqual([]);
  expect(deeplinks(`Open ${NESTED} and cmux://session/s2`).map((link) => link.href)).toEqual(["cmux://session/s2"]);
  const reply = renderToStaticMarkup(<>{linkedText(`Open ${NESTED} now`, "k")}</>);
  expect(reply).not.toContain("is-app");
  expect(reply).not.toContain("data-cmux-link");
  expect(reply.match(/<a /g)?.length).toBe(1);
  expect(reply).toContain(`href="${NESTED}"`);
  const prompt = renderToStaticMarkup(<PromptTyped text={`Open ${NESTED} now`} show={(text) => text} />);
  expect(prompt).not.toContain("is-app");
  expect(prompt.match(/<a /g)?.length).toBe(1);
  expect(prompt).toContain(`href="${NESTED}"`);
});

// A chip beside math or code copies as its link too (review of #38166): each copy path turns a chip
// into its link, so mathCopy.ts keeps the TeX and the page's code text keeps its whitespace.
function copyEvent(target: Element): { text?: string; html?: string } {
  const data = new Map<string, string>();
  const event = new window.Event("copy", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { setData: (type: string, value: string) => data.set(type, value) },
  });
  target.dispatchEvent(event);
  return event.defaultPrevented ? { text: data.get("text/plain"), html: data.get("text/html") } : {};
}

const staticChip = `<a data-cmux-link="workspace" href="${WORKSPACE}"><span class="cv-cmux-link__title">Retry fix</span></a>`;

test("a chip and an equation copy as the link and the TeX", async () => {
  const { installMathCopy } = await import("../src/agent-session/acpmux/conversation/mathCopy");
  const { installSelectionCopy } = await import("../src/agent-session/acpmux/conversation/selectionCopy");
  installSelectionCopy();
  installMathCopy();
  host.innerHTML = `<div class="cv-md"><p id="p">See ${staticChip} and <span class="cv-math" data-tex="x^2"><span class="katex">x2</span></span> here</p></div>`;
  const range = document.createRange();
  range.selectNodeContents(host.querySelector("#p")!);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(range);
  const copied = copyEvent(host.querySelector("#p")!);
  expect(copied.text).toBe(`See ${WORKSPACE} and $x^2$ here`);
  expect(copied.html).toContain(WORKSPACE);
  expect(copied.html).toContain("$x^2$");
  expect(copied.html).not.toContain("Retry fix");
  // From inside the chip's title to the equation: the whole link, then the TeX.
  range.setStart(host.querySelector(".cv-cmux-link__title")!.firstChild!, 3);
  expect(copyEvent(host.querySelector("#p")!).text).toBe(`${WORKSPACE} and $x^2$ here`);
});

test("a chip and a code block copy as the link and the code's own text", () => {
  host.innerHTML = `<div class="cv-md" id="r"><p>See ${staticChip} now</p><div class="cv-codeblock"><pre>  if (a) {\n    b();\n  }</pre></div></div>`;
  const range = document.createRange();
  range.selectNodeContents(host.querySelector("#r")!);
  expect(selectionHtml(range)).toBeNull();
  const text = chipSelectionText(range)!;
  expect(text).toContain(WORKSPACE);
  expect(text).toContain("  if (a) {\n    b();\n  }");
  expect(text).not.toContain("Retry fix");
});

test("a selection with no chip is the page's own copy", async () => {
  await mount(<PromptTyped text="Just words" show={(text) => text} />);
  expect(chipSelectionText(selectAll(host))).toBeNull();
});

// ---------------------------------------------------------------------------------------------
// The draft

let drafts = 0;

function chat(): AcpmuxSnapshot {
  const sessionId = `cmux-links-${++drafts}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
}

async function composer(typed: string) {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const snapshot = chat();
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  await mount(
    <Composer
      handle={(value) => void (handle = value)}
      snapshot={snapshot}
      sessionId={snapshot.sessionId}
      chips={() => null}
      onSend={(text) => {
        sent.push(text);
        return true;
      }}
      onStop={() => {}}
      localName="studio"
    />,
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  return { field, sent };
}

const titled = () =>
  [...host.querySelectorAll<HTMLElement>(".is-titled[data-title]")].map((node) => [
    node.dataset.title,
    node.textContent,
  ]);

test("the draft draws a known link as its chip and sends the link as pasted", async () => {
  setLinkPlaces([place("Retry fix")]);
  setPageChats(chats());
  const typed = `Compare ${WORKSPACE} with ${AGENT}`;
  const { field, sent } = await composer(typed);
  expect(titled()).toEqual([
    ["Retry fix", WORKSPACE],
    ["Review the retry fix · build-box", AGENT],
  ]);
  await act(async () => {
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Enter", keyCode: 13, bubbles: true, cancelable: true }),
    );
  });
  expect(sent).toEqual([typed]);
});

test("the draft keeps an unknown link plain text, and a place pushed later turns it into the chip", async () => {
  await composer(`See ${WORKSPACE}`);
  expect(titled()).toEqual([]);
  // Plain: the paragraph is the text alone, no element drawn around the link.
  expect(host.querySelector(".acpmux-md p")?.innerHTML).toBe(`See ${WORKSPACE}`);
  await act(async () => setLinkPlaces([place("Retry fix")]));
  expect(titled()).toEqual([["Retry fix", WORKSPACE]]);
});

test("the draft hears the page's chat list set after it mounted, and its renames", async () => {
  await composer(`Pick up ${AGENT}`);
  expect(titled()).toEqual([]);
  // App.tsx sets the page's list in a layout effect, which may run after the field subscribed.
  const store = chats();
  await act(async () => setPageChats(store));
  expect(titled()).toEqual([["Review the retry fix · build-box", AGENT]]);
  await act(async () =>
    store.set([
      {
        sessionId: "acp-reviewer",
        harness: "claude",
        agentSessionId: SESSION,
        title: "Review the retry fix, again",
        host: "build-box",
        hostKind: "cloud",
      } as AcpmuxSessionEntry,
    ]),
  );
  expect(titled()).toEqual([["Review the retry fix, again · build-box", AGENT]]);
});

test("the draft resolves a cmux.com link naming the harness's session alone to its listed chat", async () => {
  // `?session=` with no harness is the harness's own session id, never an acpmux one.
  const link = `https://cmux.com/deeplink/agent?session=${SESSION}`;
  setPageChats(chats());
  await composer(`Pick up ${link}`);
  expect(titled()).toEqual([["Review the retry fix · build-box", link]]);
});

test("a sent cmux.com link naming the harness's session alone is its listed chat's chip", async () => {
  const link = `https://cmux.com/deeplink/agent?session=${SESSION}`;
  await mount(
    <SessionHoverContext.Provider value={{ store: chats(), open: () => undefined }}>
      <PromptTyped text={`Pick up ${link}`} show={(text) => text} />
    </SessionHoverContext.Provider>,
  );
  expect(host.querySelector("[data-cmux-link=chat] .cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
});

test("the draft's chip carries its kind's icon as a mask image", async () => {
  setLinkPlaces([place("Retry fix")]);
  await composer(`See ${WORKSPACE}`);
  const chip = host.querySelector<HTMLElement>(".is-titled[data-title]")!;
  expect(chip.hasAttribute("data-icon")).toBe(true);
  expect(chip.getAttribute("style")).toContain('--cmux-link-icon: url("data:image/svg+xml,');
  expect(decodeURIComponent(chip.getAttribute("style")!)).toContain("<path");
});

// ---------------------------------------------------------------------------------------------
// The sent chip as the app ships it: with the React Compiler on (scripts/agent-pane/bundle.mjs),
// which caches what a component computes by the values it reads in render. A chip mounted before
// the host's push, or before the list has its chat, must still follow every push after it: a new
// place, a rename and a close (review of #38166: the compiler had keyed the chip's info on the link
// alone, so a sent link stayed the link, or kept its old title, after the first render).

type Compiled = {
  PromptTyped: typeof PromptTyped;
  setLinkPlaces: typeof setLinkPlaces;
  SessionHoverStore: typeof SessionHoverStore;
  SessionHoverContext: typeof SessionHoverContext;
  createRoot: typeof import("react-dom/client").createRoot;
  act: typeof act;
};

let compiled: Promise<Compiled> | undefined;
/// The chip's modules bundled with the React Compiler, once per run; its own React and stores.
function compiledChips(): Promise<Compiled> {
  compiled ??= (async () => {
    const [{ build }, { mkdtempSync, rmSync }, { tmpdir }, path, { reactCompilerPlugin }] = await Promise.all([
      import("esbuild"),
      import("node:fs"),
      import("node:os"),
      import("node:path"),
      import("../scripts/agent-pane/reactCompilerPlugin.mjs"),
    ]);
    const webviews = path.resolve(import.meta.dir, "..");
    const out = mkdtempSync(path.join(tmpdir(), "cmux-link-chips-compiled-"));
    afterAll(() => rmSync(out, { recursive: true, force: true }));
    const names = new Set<string>();
    await build({
      stdin: {
        contents: [
          'export { PromptTyped } from "./src/agent-session/acpmux/conversation/PromptText";',
          'export { setLinkPlaces } from "./src/agent-session/acpmux/chips/cmuxLinkPlaces";',
          'export { SessionHoverStore } from "./src/agent-session/acpmux/started/sessionHover";',
          'export { SessionHoverContext } from "./src/agent-session/acpmux/started/sessionHoverCardModel";',
          'export { createRoot } from "react-dom/client";',
          'export { act } from "react";',
        ].join("\n"),
        resolveDir: webviews,
        loader: "ts",
      },
      bundle: true,
      format: "esm",
      platform: "browser",
      define: { "process.env.NODE_ENV": '"development"' },
      loader: { ".css": "empty", ".svg": "text", ".woff2": "empty", ".png": "empty", ".json": "json" },
      outfile: path.join(out, "chips.js"),
      logLevel: "silent",
      plugins: [
        reactCompilerPlugin({ mode: "babel", srcRoot: path.join(webviews, "src"), onCompiled: (id) => names.add(id) }),
      ],
    });
    // The hook itself went through the compiler, or this test proves nothing.
    expect([...names]).toContain("agent-session/acpmux/chips/cmuxLinkResolve.ts:useCmuxLink");
    return (await import(path.join(out, "chips.js"))) as Compiled;
  })();
  return compiled;
}

test("compiled: a sent chip mounted first follows every push after it (new, renamed, emptied)", async () => {
  const chips = await compiledChips();
  const own = chips.createRoot(host);
  try {
    chips.setLinkPlaces([]);
    await chips.act(async () => own.render(<chips.PromptTyped text={`See ${WORKSPACE}`} show={(text) => text} />));
    expect(host.querySelector("[data-cmux-link]")).toBeNull();
    expect(host.querySelector("a.cv-link.is-app")?.getAttribute("href")).toBe(WORKSPACE);
    // The host's push arrives after the message drew: the link becomes its chip.
    await chips.act(async () => chips.setLinkPlaces([place("Retry fix")]));
    expect(host.querySelector("[data-cmux-link=workspace]")?.textContent).toBe("Retry fix");
    await chips.act(async () => chips.setLinkPlaces([place("Retry fix, take two")]));
    expect(host.querySelector("[data-cmux-link=workspace]")?.textContent).toBe("Retry fix, take two");
    await chips.act(async () => chips.setLinkPlaces([place("Retry fix, take two", { host: "build-box" })]));
    expect(host.querySelector(".cv-cmux-link__host")?.textContent).toBe("build-box");
    // Closed: the link again.
    await chips.act(async () => chips.setLinkPlaces([]));
    expect(host.querySelector("[data-cmux-link]")).toBeNull();
    expect(host.querySelector("a.cv-link.is-app")?.getAttribute("href")).toBe(WORKSPACE);
  } finally {
    chips.act(() => own.unmount());
  }
});

test("compiled: a sent chat chip mounted first follows the list (listed later, renamed, gone)", async () => {
  const chips = await compiledChips();
  const store = new chips.SessionHoverStore();
  const entry = (title: string) =>
    ({
      sessionId: "acp-reviewer",
      harness: "claude",
      agentSessionId: SESSION,
      title,
      host: "build-box",
      hostKind: "cloud",
    }) as AcpmuxSessionEntry;
  const own = chips.createRoot(host);
  try {
    await chips.act(async () =>
      own.render(
        <chips.SessionHoverContext.Provider value={{ store, open: () => undefined }}>
          <chips.PromptTyped text={`Pick up ${AGENT}`} show={(text) => text} />
        </chips.SessionHoverContext.Provider>,
      ),
    );
    expect(host.querySelector("[data-cmux-link]")).toBeNull();
    await chips.act(async () => store.set([entry("Review the retry fix")]));
    expect(host.querySelector("[data-cmux-link=chat] .cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
    await chips.act(async () => store.set([entry("Review the retry fix, again")]));
    expect(host.querySelector("[data-cmux-link=chat] .cv-cmux-link__title")?.textContent).toBe(
      "Review the retry fix, again",
    );
    await chips.act(async () => store.set([]));
    expect(host.querySelector("[data-cmux-link]")).toBeNull();
  } finally {
    chips.act(() => own.unmount());
  }
});
