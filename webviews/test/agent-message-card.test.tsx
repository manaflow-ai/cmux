// l10n-allow-file: test fixtures.
// Another agent's message, opened (conversation/IncomingMessageCard.tsx; Leo 2026-10-21: "we can
// render this with pics maybe and just... idk make it all look nicer" and "can you just enable all
// these"): its sender's signature is out; every file it names is a chip that
// opens it, through the reply chips' host calls, with no lock when outside paths open; an image is
// also a thumbnail; a bare name is the file in the folder of the full path before it; a pull
// request written twice in a row is one chip; a commit SHA is quiet monospace; and a message from
// another machine names that machine's files, which draw with its name and a lock and are never
// asked about here.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

const { createRoot } = await import("react-dom/client");
const { IncomingMessageLine } = await import("../src/agent-session/acpmux/conversation/IncomingMessageCard");
const { SubsessionContext, SubsessionStore } = await import("../src/agent-session/acpmux/subagents/subsessions");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");

afterAll(() => {
  act(() => root?.unmount());
  setChipHost(undefined);
  resetLinkStore();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
const TEXT = [
  "[agent-message-style] MERGED #23825 (4c656ea8) manaflow-ai/cmux#23825 — the line is the agent row.",
  "Screenshots: /tmp/lane/before.png, after.png and webviews/src/model.ts.",
].join("\n");

/// Renders the message from chat `lane-1` opened, with the host answering every path as outside
/// the chat's folders under `outsideRoots: "open"`, and returns what the host was asked.
async function render(
  message: Record<string, unknown>,
  sessions: Record<string, unknown>[],
  placeOf: (path: string) => string = () => "outside",
  readable: (src: string) => boolean = () => true,
) {
  resetLinkStore();
  const asked: { method: string; params: Record<string, unknown> }[] = [];
  setChipHost(async (method, params) => {
    asked.push({ method, params });
    if (method === "link.inspect") {
      const paths = (params.paths as string[]) ?? [];
      return {
        paths: Object.fromEntries(paths.map((path) => [path, { place: placeOf(path), folder: false }])),
        policy: { outsideRoots: "open", remoteImages: "click" },
      };
    }
    if (method === "image.load") return readable(params.src as string) ? { src: PNG } : null;
    return null;
  });
  const store = new SubsessionStore();
  store.set(sessions as never);
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <SubsessionContext.Provider value={{ store, open: () => {} }}>
        <IncomingMessageLine
          id={`row-${Math.random()}`}
          message={{ name: "agent-message-style", sessionId: "lane-1", text: TEXT, raw: TEXT, ...message } as never}
          onOpen={() => {}}
          githubRepository="manaflow-ai/cmux"
        />
      </SubsessionContext.Provider>,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>(".cv-received__toggle")!.click());
  // The chips ask the host in a microtask; their answers draw on the next.
  for (let i = 0; i < 4; i++) await act(async () => await new Promise((done) => setTimeout(done, 0)));
  return asked;
}

test("a message's files open, its images are thumbnails, its PR one chip, its SHA quiet, no signature", async () => {
  const asked = await render({}, [
    { sessionId: "lane-1", name: "agent-message-style", cwd: "/w/cmux", hostKind: "local" },
  ]);
  const body = host.querySelector(".cv-received__body")!;
  const chips = [...body.querySelectorAll<HTMLElement>("button.cv-chip.is-path")].map((chip) => chip.dataset.path);
  expect(chips).toEqual(["/w/cmux/webviews/src/model.ts"]);
  // Each screenshot draws once: its thumbnail, and its mention is a quiet link, not a second chip.
  const mentions = [...body.querySelectorAll<HTMLElement>(".is-image-mention")].map((link) => link.dataset.path);
  expect(mentions).toEqual(["/tmp/lane/before.png", "/tmp/lane/after.png"]);
  // Outside the chat's folders, but they open on a click: no lock.
  expect(body.querySelector(".cv-chip__lock")).toBeNull();
  // Both screenshots draw as thumbnails in the strip under the text, loaded through the host.
  expect(body.querySelectorAll(".cv-received__pics .cv-thumb img")).toHaveLength(2);
  expect(body.querySelectorAll(".cv-received__text .cv-thumb")).toHaveLength(0);
  expect(asked.filter((call) => call.method === "image.load").map((call) => call.params.src)).toEqual([
    "/tmp/lane/before.png",
    "/tmp/lane/after.png",
  ]);
  // A click opens the file through the host's file route.
  await act(async () =>
    body.querySelector<HTMLButtonElement>('.is-image-mention[data-path="/tmp/lane/after.png"]')!.click(),
  );
  expect(asked.at(-1)).toEqual({ method: "link.openPath", params: { path: "/tmp/lane/after.png" } });
  // #23825 written twice in a row is one chip; the SHA is quiet text linking its commit.
  const refs = [...body.querySelectorAll(".cv-chip.is-ref")].map((chip) => chip.textContent);
  expect(refs).toEqual(["#23825"]);
  const sha = body.querySelector<HTMLAnchorElement>("a.cv-sha")!;
  expect(sha.textContent).toBe("4c656ea8");
  expect(sha.getAttribute("href")).toBe("https://github.com/manaflow-ai/cmux/commit/4c656ea8");
  // The sender's signature is out.
  expect(body.textContent!.startsWith("MERGED")).toBe(true);
  expect(body.textContent).not.toContain("[agent-message-style]");
});

test("a message from another machine names its files there: chips with a lock, never asked about here", async () => {
  const asked = await render({ sessionId: undefined, remote: true }, []);
  const body = host.querySelector(".cv-received__body")!;
  expect(body.querySelector("button.cv-chip.is-path")).toBeNull();
  const elsewhere = [...body.querySelectorAll<HTMLElement>(".cv-chip.is-elsewhere")];
  expect(elsewhere.map((chip) => chip.dataset.path)).toEqual(["/tmp/lane/before.png", "/tmp/lane/after.png"]);
  expect(elsewhere.every((chip) => chip.querySelector(".cv-chip__lock"))).toBe(true);
  expect(elsewhere[0]!.getAttribute("title")).toBe("On another machine: /tmp/lane/before.png");
  expect(body.querySelector(".cv-thumb")).toBeNull();
  expect(asked.some((call) => call.method === "image.load" || call.method === "link.openPath")).toBe(false);
  const inspected = asked.flatMap((call) => (call.method === "link.inspect" ? (call.params.paths as string[]) : []));
  expect(inspected).toEqual([]);

  // A listed chat on a peer names its machine.
  await render({ remote: true }, [
    { sessionId: "lane-1", name: "agent-message-style", peer: "air-blue", cwd: "/Users/x/lane" },
  ]);
  const named = host.querySelector<HTMLElement>(".cv-received__body .cv-chip.is-elsewhere")!;
  expect(named.getAttribute("title")).toBe("On air-blue: /tmp/lane/before.png");
});

test("a name the card wrote out in full that is not there draws as the agent wrote it", async () => {
  // Paths no other test loads: an image's load is remembered across renders.
  const text = "Screenshots: /tmp/gone/shown.png, lost.png and webviews/src/lost.ts.";
  await render(
    { text, raw: text },
    [{ sessionId: "lane-1", name: "agent-message-style", cwd: "/w/cmux", hostKind: "local" }],
    (path) => (path.includes("lost") ? "missing" : "outside"),
  );
  const body = host.querySelector(".cv-received__body")!;
  const mentions = [...body.querySelectorAll<HTMLElement>(".is-image-mention")].map((link) => link.dataset.path);
  expect(mentions).toEqual(["/tmp/gone/shown.png"]);
  const plain = [...body.querySelectorAll(".cv-chip-plain")].map((span) => span.textContent);
  expect(plain).toEqual(["lost.png", "webviews/src/lost.ts"]);
  expect(body.textContent).not.toContain("/w/cmux/");
  // The missing screenshot draws no thumbnail: its name in the text says enough.
  expect(body.querySelectorAll(".cv-received__pics .cv-thumb")).toHaveLength(1);
});

test("Leo's case: two screenshots on this Mac each draw once; one the host cannot read is a compact chip", async () => {
  // Leo 2026-10-21: "will things properly render yet?" ... "why is there those 2 cards???"
  const shots = "/tmp/composer-look/model-menu";
  const text = `[composer-look] Model-menu after-shots: ${shots}/after-claude-model-menu.png (4 models) and ${shots}/after-claude-effort-up.png (the submenu opens upward).`;
  await render({ name: "composer-look", text, raw: text }, [
    { sessionId: "lane-1", name: "composer-look", cwd: "/w/cmux", hostKind: "local" },
  ]);
  let body = host.querySelector(".cv-received__body")!;
  expect(body.querySelectorAll(".cv-received__pics .cv-thumb img")).toHaveLength(2);
  expect([...body.querySelectorAll<HTMLElement>(".is-image-mention")].map((link) => link.textContent)).toEqual([
    "after-claude-model-menu.png",
    "after-claude-effort-up.png",
  ]);
  expect(body.querySelector("button.cv-chip.is-path")).toBeNull();
  expect(body.querySelector(".cv-image-file, .cv-chip__lock")).toBeNull();
  expect(body.textContent!.startsWith("Model-menu")).toBe(true);

  // An image the host will not read: one compact chip in the text, nothing in the strip.
  const lost = "/tmp/composer-look/unread/after-claude-model-menu.png";
  const one = `[composer-look] Shot: ${lost} (4 models).`;
  await render(
    { name: "composer-look", text: one, raw: one },
    [{ sessionId: "lane-1", name: "composer-look", cwd: "/w/cmux", hostKind: "local" }],
    () => "outside",
    (src) => src !== lost,
  );
  body = host.querySelector(".cv-received__body")!;
  expect([...body.querySelectorAll<HTMLElement>("button.cv-chip.is-path")].map((chip) => chip.dataset.path)).toEqual([
    lost,
  ]);
  expect(body.querySelector(".is-image-mention")).toBeNull();
  expect(body.querySelector(".cv-received__pics .cv-thumb, .cv-image-file")).toBeNull();
});
