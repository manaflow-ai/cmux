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
//   - every state acpmux recovers from by itself (connecting, reconnecting, offline) is the dot alone,
//     with no spinner, no words and no Reconnect, at any duration (Leo, 2026-11-22: "i dont wanna see
//     connecting to cosmic-gray... with the spinner, i want it to just work"); only a step a person
//     must take (a refused sign-in, an update) names the machine and the step;
//   - the row's element stays one element through every state, so the row's other controls stay put.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { chat, summary, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
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
  jest.useRealTimers();
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

async function render(snapshot: AcpmuxSnapshot) {
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
const stateWords = () => link()?.querySelector(".acpmux-machine-link-state")?.textContent ?? "";
const spinner = () => host.querySelector(".acpmux-composer-foot .acpmux-machine-link-spinner");

test("a chat on this Mac draws no machine link", async () => {
  await render(started());
  expect(host.querySelector(".acpmux-composer-foot")).not.toBeNull();
  expect(host.querySelector(".acpmux-machine-link")).toBeNull();
});

test("a peer chat's row draws only the dot for every state acpmux recovers from, in one element", async () => {
  await render(started("walk-remote", "connected"));
  const element = link();
  expect(element?.dataset.link).toBe("connected");
  // Connected is the dot alone; the machine is its name, not its text.
  expect(element?.hasAttribute("data-said")).toBe(false);
  expect(element?.getAttribute("aria-label")).toBe("walk-remote");
  expect(reconnect()).toBeNull();

  for (const state of ["connecting", "reconnecting", "restarting", "degraded", "offline"] as const) {
    await render(started("walk-remote", state));
    expect(link(), state).toBe(element);
    // The dot keeps its connected look: no spinner, no words, no Reconnect.
    expect(link()?.dataset.link, state).toBe("connected");
    expect(link()?.hasAttribute("data-said"), state).toBe(false);
    expect(link()?.getAttribute("aria-label"), state).toBe("walk-remote");
    expect(spinner(), state).toBeNull();
    expect(reconnect(), state).toBeNull();
    expect(host.querySelector(".acpmux-composer-foot")?.textContent ?? "", state).not.toMatch(
      /Connecting|Reconnecting|Offline/,
    );
  }

  await render(started("walk-remote", "connected"));
  expect(link()).toBe(element);
  expect(link()?.hasAttribute("data-said")).toBe(false);
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

test("an open Cloud chat whose link drops with no banner keeps the plain dot", async () => {
  // The chat is still read from its machine (no Mac's copy, so no peer copy banner): nothing says the
  // link is coming back, it just comes back.
  await render(started("dev-vm-2", "connected", "cloud"));
  await render(started("dev-vm-2", "reconnecting", "cloud"));
  expect(link()?.dataset.link).toBe("connected");
  expect(link()?.hasAttribute("data-said")).toBe(false);
  expect(spinner()).toBeNull();
  expect(said()).not.toContain("Reconnecting");
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

// Leo, 2026-11-22: "i dont wanna see connecting to cosmic-gray... with the spinner, i want it to just
// work". A link acpmux brings back on its own is never said here, however long it is down; a step a
// person must take is said at once; and one cause is said in one place.

/// A peer chat whose link acpmux says is `link`, since `since` (ms since the epoch).
function linked(peer: string, link: string, since: number, extra: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const snapshot = started(peer, undefined, "ssh");
  return { ...snapshot, peerLinks: { [peer]: { link, since } }, ...extra } as AcpmuxSnapshot;
}

test("a link that dropped keeps the plain dot, with no spinner or words, at any duration", async () => {
  jest.useFakeTimers();
  await render(started("walk-remote", "connected"));
  const element = link();
  for (const state of ["degraded", "reconnecting", "connecting", "offline"]) {
    await render(linked("walk-remote", state, Date.now()));
    expect(link(), state).toBe(element);
    expect(link()?.hasAttribute("data-said"), state).toBe(false);
    expect(spinner(), state).toBeNull();
    await act(async () => void jest.advanceTimersByTime(10 * 60_000));
    expect(link()?.hasAttribute("data-said"), state).toBe(false);
    expect(spinner(), state).toBeNull();
    expect(stateWords(), state).toBe("");
  }
});

test("a link acpmux has had down for an hour still says nothing", async () => {
  await render(linked("walk-remote", "offline", Date.now() - 3_600_000));
  expect(link()?.hasAttribute("data-said")).toBe(false);
  expect(stateWords()).toBe("");
  expect(reconnect()).toBeNull();
});

test("a refused sign-in or an update the machine needs is said at once", async () => {
  for (const [state, words] of [
    ["authFailed", "Sign-in needed"],
    ["updateRequired", "Update required"],
  ] as const) {
    await render(linked("walk-remote", state, Date.now()));
    expect(link()?.hasAttribute("data-said"), state).toBe(true);
    expect(said(), state).toBe(`walk-remote${words}`);
  }
});

test("an ssh link the peer copy banner or the missing chat's state already says is not said again here", async () => {
  await render(started("walk-remote", "offline", "ssh", true));
  expect(link()).toBeNull();
  await render(
    linked("walk-remote", "reconnecting", 0, { unavailable: { reason: "offline", machine: "walk-remote" } }),
  );
  expect(link()).toBeNull();
  // A step only a person can take stays in the row.
  await render(started("walk-remote", "authFailed", "ssh", true));
  expect(said()).toBe("walk-remoteSign-in needed");
});
