// Review follow-ups of #38166 (pasted cmux links drawn as chips; Leo, 2026-11-08: "it should be able
// to render in the box that it is an actual chat that is there, like with the title and whatever,
// and, like, to be potentially hoverable as well"):
// - a peer's chat link, named only by acpmux's resolve, shows a hover card (the link card);
// - a cloud group link (`cmux://group/grp_…`) is a link the pane draws and the host opens;
// - a native agent link whose hint is percent-encoded or malformed stays a link;
// - a Markdown link to a cmux target (`[label](cmux://…)`) draws as the chip, with its label.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Root } from "react-dom/client";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import { appHref, linkHref } from "../src/agent-session/acpmux/replyHref";
import { parseLink } from "../src/pages/markdown/links";
import { setLinkPlaces } from "../src/agent-session/acpmux/chips/cmuxLinkPlaces";
import { setPageChats } from "../src/agent-session/acpmux/chips/cmuxLinkResolve";
import { linkedText } from "../src/agent-session/acpmux/chips/linkedText";
import { renderInline } from "../src/agent-session/acpmux/conversation/inlineMarkdown";
import { chipsAsLinks } from "../src/agent-session/acpmux/conversation/chipCopy";
import { SessionHoverStore } from "../src/agent-session/acpmux/started/sessionHover";
import { SessionHoverContext } from "../src/agent-session/acpmux/started/sessionHoverCardModel";
import { resetSessionRefs, setSessionRefResolver } from "../src/agent-session/acpmux/conversation/sessionRefs";
import { teardownDom } from "./support/domTeardown";

const HEX = "16c92e4354fcaf05540386720d78e251";
const WORKSPACE = `cmux-nightly://workspace/ws_${HEX}`;
const SESSION = "9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
const AGENT = `cmux://agent/claude/${SESSION}`;
const PEER = "4e8a2d6c-1b3f-4a5e-9c7d-0f1e2d3c4b5a";
const PEER_AGENT = `cmux://agent/codex/${PEER}?host=studio&name=peer`;
const GROUP = "cmux://group/grp_abcdefghij0123456789";
const GROUP_WORKSPACE = `${GROUP}/workspace/ws_${HEX}`;

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
  "requestIdleCallback",
  "cancelIdleCallback",
  "localStorage",
  "MouseEvent",
  "FocusEvent",
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
    // The page is idle at once: acpmux is asked as soon as a chip mounts (sessionRefs.ts whenIdle).
    requestIdleCallback: (run: () => void) => {
      queueMicrotask(run);
      return 0;
    },
    cancelIdleCallback: () => undefined,
    localStorage: window.localStorage,
    MouseEvent: window.MouseEvent,
    FocusEvent: window.FocusEvent,
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
  setSessionRefResolver(undefined);
  resetSessionRefs();
});

afterAll(async () => {
  setLinkPlaces([]);
  setPageChats(undefined);
  await teardownDom(saved, { window: dom.window, scope });
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

/// Mounts `node` with the session list and acpmux answering `answers` (a query it has no answer
/// for names no chat of the reader's); returns once every answer is drawn.
async function mount(node: ReactNode, answers: Record<string, Record<string, unknown>> = {}) {
  const answered: Promise<unknown>[] = [];
  setSessionRefResolver((query) => {
    const session = answers[query];
    const answer = session ? Promise.resolve({ session }) : Promise.reject(new Error("not found"));
    answered.push(answer.catch(() => undefined));
    return answer;
  });
  const { createRoot } = await import("react-dom/client");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <SessionHoverContext.Provider value={{ store: chats(), open: () => undefined }}>
        {node}
      </SessionHoverContext.Provider>,
    ),
  );
  await act(async () => {
    await Promise.resolve();
    await Promise.all(answered);
  });
}

async function focus(element: HTMLElement) {
  await act(async () => {
    element.focus();
    element.dispatchEvent(new window.FocusEvent("focus", { bubbles: false }));
    element.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  });
}

/// Inline Markdown as a reply draws it.
function Markdown({ text }: { text: string }) {
  return <p className="cv-md">{renderInline(text)}</p>;
}

// ---------------------------------------------------------------------------------------------
// A peer's chat: its hover card

test("a peer's chat chip, named only by acpmux's resolve, shows a link card on hover", async () => {
  await mount(<p>{linkedText(`Ask ${PEER_AGENT}`, "r")}</p>, {
    [PEER_AGENT]: { sessionId: "acp-peer", name: "Peer review", host: "studio" },
  });
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.querySelector(".cv-cmux-link__title")?.textContent).toBe("Peer review");
  expect(document.querySelector(".cv-cmux-link-card")).toBeNull();
  await focus(chip);
  const card = document.querySelector(".cv-cmux-link-card");
  expect(card).not.toBeNull();
  expect(card!.querySelector(".cv-link-preview__site")?.textContent).toBe("Peer review");
  expect(card!.querySelector(".cv-link-preview__target")?.textContent).toBe("Chat on studio");
  expect(card!.querySelector(".cv-cmux-link-card__link")?.textContent).toBe(PEER_AGENT);
  // Not the session card: the list has no such chat to show.
  expect(document.querySelector(".acpmux-session-hover")).toBeNull();
});

test("a listed chat's chip keeps its session card, never the link card", async () => {
  await mount(<p>{linkedText(`Ask ${AGENT}`, "r")}</p>);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]")!;
  expect(chip.querySelector(".cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
  await focus(chip);
  expect(document.querySelector(".cv-cmux-link-card")).toBeNull();
});

// ---------------------------------------------------------------------------------------------
// Cloud group links

test("a cloud group link is a link the pane draws, bare or in Markdown, and the Markdown page follows", () => {
  for (const link of [GROUP, GROUP_WORKSPACE, `cmux-nightly://group/grp_abcdefghij0123456789`]) {
    expect(appHref(link)).toBe(link);
    expect(linkHref(link)).toBe(link);
    expect(parseLink(link).kind).toBe("app");
  }
  const bare = renderToStaticMarkup(<p>{linkedText(`Open ${GROUP_WORKSPACE} now`, "g")}</p>);
  expect(bare).toContain(`class="cv-link is-app" href="${GROUP_WORKSPACE}"`);
  const markdown = renderToStaticMarkup(<Markdown text={`Open [the team group](${GROUP})`} />);
  expect(markdown).toContain(`href="${GROUP}"`);
  expect(markdown).toContain("the team group");
});

// ---------------------------------------------------------------------------------------------
// An agent link's percent-encoded or malformed hint

test("a native agent link with a percent-encoded or malformed hint stays a link", () => {
  for (const link of [
    `cmux://agent/claude/${SESSION}?host=a%20b`,
    `cmux://agent/claude/${SESSION}?name=Lantern%2Ffish&host=studio`,
    `cmux://agent/claude/${SESSION}?host=a%zz`,
  ]) {
    expect(appHref(link)).toBe(link);
    expect(parseLink(link).kind).toBe("app");
    expect(renderToStaticMarkup(<p>{linkedText(`See ${link}`, "a")}</p>)).toContain(
      `href="${link.replace(/&/g, "&amp;")}"`,
    );
  }
});

test("a percent-encoded hint drawn in a reply is the listed chat's chip", async () => {
  const link = `${AGENT}?host=a%20b`;
  await mount(<p>{linkedText(`See ${link}`, "a")}</p>);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]");
  expect(chip?.getAttribute("href")).toBe(link);
  expect(chip?.querySelector(".cv-cmux-link__title")?.textContent).toBe("Review the retry fix");
});

// ---------------------------------------------------------------------------------------------
// Markdown links to cmux targets

test("a Markdown link to a known workspace draws as its chip with the author's label", async () => {
  setLinkPlaces([{ id: `ws_${HEX}`, kind: "workspace", title: "Retry fix", host: "studio" }]);
  await mount(<Markdown text={`See [the **notice** rows](${WORKSPACE}) first.`} />);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=workspace]");
  expect(chip).not.toBeNull();
  expect(chip!.getAttribute("href")).toBe(WORKSPACE);
  expect(chip!.querySelector(".cv-cmux-link__title")?.textContent).toBe("the notice rows");
  expect(chip!.querySelector(".cv-cmux-link__title strong")?.textContent).toBe("notice");
  expect(chip!.querySelector(".cv-cmux-link__icon")).not.toBeNull();
  expect(chip!.querySelector(".cv-cmux-link__host")?.textContent).toBe("studio");
  expect(host.querySelector("a.cv-link.is-app")).toBeNull();
  // Its card still names what it opens.
  await focus(chip!);
  expect(document.querySelector(".cv-cmux-link-card .cv-link-preview__site")?.textContent).toBe("Retry fix");
});

test("a Markdown link to a listed chat draws as its chip with the author's label", async () => {
  await mount(<Markdown text={`Ask [the reviewer](${AGENT}).`} />);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]");
  expect(chip?.getAttribute("href")).toBe(AGENT);
  expect(chip?.querySelector(".cv-cmux-link__title")?.textContent).toBe("the reviewer");
});

test("a Markdown link to a cmux.com agent link of a listed chat draws as its chip with the label", async () => {
  const web = `https://cmux.com/deeplink/agent?harness=claude&session=${SESSION}`;
  await mount(<Markdown text={`Ask [the reviewer](${web}).`} />);
  const chip = host.querySelector<HTMLAnchorElement>("[data-cmux-link=chat]");
  expect(chip?.getAttribute("href")).toBe(web);
  expect(chip?.querySelector(".cv-cmux-link__title")?.textContent).toBe("the reviewer");
});

test("a Markdown link nothing names stays its labelled link", async () => {
  await mount(<Markdown text={`See [the old one](cmux://workspace/ws_${"0".repeat(32)}).`} />);
  expect(host.querySelector("[data-cmux-link]")).toBeNull();
  const link = host.querySelector<HTMLAnchorElement>("a.cv-link.is-app");
  expect(link?.textContent).toBe("the old one");
});

test("a Markdown link's chip copies as its label, as its plain anchor did; a bare link's as its link", async () => {
  setLinkPlaces([{ id: `ws_${HEX}`, kind: "workspace", title: "Retry fix" }]);
  await mount(
    <div>
      <Markdown text={`See [the rows](${WORKSPACE}).`} />
      <p>{linkedText(`And ${WORKSPACE}.`, "b")}</p>
    </div>,
  );
  const clone = host.cloneNode(true) as HTMLElement;
  chipsAsLinks(clone);
  expect(clone.textContent).toBe(`See the rows.And ${WORKSPACE}.`);
});
