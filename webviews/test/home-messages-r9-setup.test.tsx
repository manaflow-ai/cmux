// Review round 9 of cmux#37736, F1: the first-run "Set Up cmux" card (#39240, #39270, #39388) that the
// native Chief chat hosted (HomeHostView+SetupCard) shows on the React Messages page too, pinned under a
// Chief chat's header while the host says it shows; none in any other chat; Hide goes
// to the host as on the setup-card page.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { useSetupCard, HOME_SETUP_OPS } = await import("../src/pages/home-messages/detail/HomeSetupCard");
const { cardStrings } = await import("../src/pages/home-messages/cards/strings");
type PageClient = import("../src/pages/shared/pageClient").PageClient;
type SetupState = import("../src/pages/home-messages/cards/setup/setupModel").SetupState;

const strings = cardStrings(["en"]);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const fresh: SetupState = {
  agents: [
    { id: "claude", name: "Claude Code", state: "missing" },
    { id: "codex", name: "Codex", state: "missing" },
  ],
  account: { signedIn: false },
  cli: "missing",
  classic: null,
};

/** A host whose `shows` stream the test drives; `state` answers the card's rows; every call is kept. */
function fakeHost() {
  const calls: { op: string; params: unknown }[] = [];
  const streams = new Map<string, (event: unknown) => void>();
  const host = {
    call: async (op: string, params: unknown = {}) => {
      calls.push({ op, params });
      return op === HOME_SETUP_OPS.state ? fresh : {};
    },
    subscribe: async (stream: string, onEvent: (event: unknown) => void) => {
      streams.set(stream, onEvent);
      if (stream === HOME_SETUP_OPS.shows) onEvent({ shows: false });
      return () => streams.delete(stream);
    },
    handle: () => () => {},
  } as unknown as PageClient;
  return { host, calls, emit: (stream: string, event: unknown) => streams.get(stream)?.(event) };
}

function Harness({ host, isChief }: { host: PageClient; isChief: boolean }) {
  return <div>{useSetupCard(host, isChief, strings)}</div>;
}

async function render(container: HTMLElement, host: PageClient, isChief: boolean) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<Harness host={host} isChief={isChief} />);
  });
  await settle();
}

const button = (container: HTMLElement, label: string) =>
  [...container.querySelectorAll("button")].find((node) => node.textContent === label);

test("a Chief chat shows Set Up cmux while the host says it shows, and Hide goes to the host", async () => {
  const container = installDom();
  const { host, calls, emit } = fakeHost();
  await render(container, host, true);
  expect(container.querySelector(".hm-setup")).toBeNull();

  await act(async () => emit(HOME_SETUP_OPS.shows, { shows: true }));
  await settle();
  expect(container.querySelector(".hm-setup-pinned .hm-setup")).not.toBeNull();
  expect(container.textContent).toContain("Set Up cmux");
  expect(calls.some((call) => call.op === HOME_SETUP_OPS.state)).toBe(true);

  await act(async () => button(container, "Hide")!.click());
  expect(calls.at(-1)).toEqual({ op: HOME_SETUP_OPS.hide, params: {} });

  // The host ends it (Hide, or every row done): the card goes.
  await act(async () => emit(HOME_SETUP_OPS.shows, { shows: false }));
  await settle();
  expect(container.querySelector(".hm-setup")).toBeNull();
});

test("no card in a chat that is not a Chief's", async () => {
  const container = installDom();
  const { host, calls, emit } = fakeHost();
  await render(container, host, false);
  await act(async () => emit(HOME_SETUP_OPS.shows, { shows: true }));
  await settle();
  expect(container.querySelector(".hm-setup")).toBeNull();
  expect(calls.some((call) => call.op === HOME_SETUP_OPS.state)).toBe(false);
});
