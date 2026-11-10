// l10n-allow-file: test fixture machine names, not shipped UI.
//
// A chat on another machine says what its link is doing in the composer's quiet row (goal
// remote-reconnect-fast, Leo 2026-11-07: "with a connection UI that says plainly what is
// happening"). A remote-reconnect probe found nothing on screen 40 s into a dropped link but the
// model chip's "Unavailable": nothing drew the link of a peer chat opened with
// `cmux agent open-tab NAME --host PEER`.
//
//   - a chat on an acpmux peer reads only that peer's link as acpmux reports it (`peerStates`), and a
//     chat on this Mac draws nothing;
//   - connected is the dot alone; connecting, reconnecting and offline name the machine and the
//     sidebar header's word for the state; offline offers Reconnect, which asks acpmux for the peer;
//   - the row's element stays one element through every state, so the row's other controls stay put.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { chat, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { PeerLink } from "../src/agent-session/acpmux/peerLink";
import { teardownDom } from "./support/domTeardown";

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
  "MouseEvent",
  "Event",
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
    MouseEvent: window.MouseEvent,
    Event: window.Event,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

async function render(snapshot: AcpmuxSnapshot, onReconnectMachine?: (link: PeerLink) => Promise<unknown> | void) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={() => true}
        onStop={() => {}}
        localName="studio"
        onReconnectMachine={onReconnectMachine}
      />,
    ),
  );
}

/// A started chat; on peer `peer` when given, whose link acpmux says is `state`. With `banner`, the
/// chat is drawn from the Mac's copy while its machine does not answer, so the peer copy banner shows.
function started(peer?: string, state?: string, kind: "ssh" | "cloud" = "ssh", banner = false): AcpmuxSnapshot {
  const snapshot = chat([user("hello", 3), summary(2, { status: "completed" })], { title: "Reconnect" });
  return {
    ...snapshot,
    ...(peer && banner ? { peerCopy: { peer, offline: true } } : {}),
    summary: { ...snapshot.summary!, ...(peer ? { peer } : {}) },
    ...(peer ? { peerKinds: { [peer]: kind } } : {}),
    ...(peer && state ? { peerStates: { [peer]: state } } : {}),
  };
}

const link = () => host.querySelector<HTMLElement>(".acpmux-composer-foot > .acpmux-machine-link");
const said = () => link()?.querySelector(".acpmux-machine-link-said")?.textContent ?? "";
const reconnect = () => link()?.querySelector<HTMLButtonElement>(".acpmux-machine-link-reconnect") ?? null;

test("a chat on this Mac draws no machine link", async () => {
  await render(started());
  expect(host.querySelector(".acpmux-composer-foot")).not.toBeNull();
  expect(host.querySelector(".acpmux-machine-link")).toBeNull();
});

test("a peer chat's row says each link state in the sidebar's words, in one element", async () => {
  await render(started("walk-remote", "connected"));
  const element = link();
  expect(element?.dataset.link).toBe("connected");
  // Connected is the dot alone; the machine and its state are its name, not its text.
  expect(element?.hasAttribute("data-said")).toBe(false);
  expect(element?.getAttribute("aria-label")).toBe("walk-remote · Connected");
  expect(reconnect()).toBeNull();

  for (const [state, link_, words] of [
    ["connecting", "connecting", "Connecting…"],
    ["reconnecting", "connecting", "Reconnecting…"],
    ["restarting", "connecting", "Reconnecting…"],
    ["degraded", "connecting", "Reconnecting…"],
    ["offline", "offline", "Offline"],
  ] as const) {
    await render(started("walk-remote", state));
    expect(link(), state).toBe(element);
    expect(link()?.dataset.link, state).toBe(link_);
    expect(link()?.hasAttribute("data-said"), state).toBe(true);
    expect(said(), state).toBe(`walk-remote${words}`);
    expect(link()?.getAttribute("aria-label"), state).toBe(`walk-remote · ${words}`);
    expect(reconnect() !== null, state).toBe(false);
  }

  // Back: the words fold away, the same element keeps the dot.
  await render(started("walk-remote", "connected"));
  expect(link()).toBe(element);
  expect(link()?.hasAttribute("data-said")).toBe(false);
});

test("an offline peer offers Reconnect, which asks for that peer", async () => {
  const asked: PeerLink[] = [];
  let answer!: () => void;
  await render(started("walk-remote", "offline"), (pressed) => {
    asked.push(pressed);
    return new Promise<void>((resolve) => (answer = resolve));
  });
  const button = reconnect()!;
  expect(button.textContent).toBe("Reconnect");
  await act(async () => button.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  expect(asked).toEqual([{ machine: "walk-remote", link: "offline" }]);
  expect(reconnect()?.disabled).toBe(true);
  expect(reconnect()?.textContent).toBe("Reconnecting…");
  await act(async () => answer());
  expect(reconnect()?.disabled).toBe(false);
});

test("a Cloud peer that does not answer leaves it to the peer copy banner", async () => {
  await render(started("dev-vm-2", "connected", "cloud"));
  expect(link()?.dataset.link).toBe("connected");
  for (const state of ["offline", "connecting", "reconnecting", "restarting", "degraded"]) {
    await render(started("dev-vm-2", state, "cloud", true));
    expect(link(), state).toBeNull();
  }
});

test("a paused Cloud peer that was connected draws no Reconnecting spinner", async () => {
  // A Cloud machine that was connected keeps its last_seen, so acpmux reports its pause as reconnecting.
  await render(started("dev-vm-2", "connected", "cloud"));
  expect(link()).not.toBeNull();
  await render(started("dev-vm-2", "reconnecting", "cloud", true));
  expect(link()).toBeNull();
  expect(host.querySelector(".acpmux-composer-foot .acpmux-machine-link-spinner")).toBeNull();
  expect(host.querySelector(".acpmux-composer-foot")?.textContent ?? "").not.toContain("Reconnecting");
});

test("an open Cloud chat whose link drops with no banner keeps its warning in the footer", async () => {
  // The chat is still read from its machine (no Mac's copy, so no peer copy banner): the footer is the
  // only place that says the link is coming back.
  await render(started("dev-vm-2", "connected", "cloud"));
  await render(started("dev-vm-2", "reconnecting", "cloud"));
  expect(link()?.dataset.link).toBe("connecting");
  expect(said()).toBe("dev-vm-2Reconnecting…");
});

test("a Cloud peer whose sign-in or build needs a person still says so", async () => {
  // Only the Cloud states that come back on their own are the peer copy banner's: a refused sign-in or
  // a build the machine needs waits for a person, and the banner offers only Resume.
  for (const [state, words] of [
    ["authFailed", "Sign-in needed"],
    ["updateRequired", "Update required"],
  ] as const) {
    await render(started("dev-vm-2", state, "cloud"));
    expect(link()?.dataset.link, state).toBe("offline");
    expect(said(), state).toBe(`dev-vm-2${words}`);
    expect(reconnect(), state).toBeNull();
  }
});

test("the model chip no longer reads Unavailable for a machine that is down", async () => {
  const { authChipText, readSessionAuth } = await import("../src/agent-session/acpmux/sessionAuth");
  expect(
    authChipText(readSessionAuth({ state: "peerUnreachable", source: "peerLink", evidenceAt: 1, host: "walk-remote" })),
  ).toBeUndefined();
});
