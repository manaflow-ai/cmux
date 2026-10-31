// l10n-allow-file: test names and fixture text, not shipped UI.
// A web link's site mark (chips/SiteIcon.tsx, siteIcons.ts): the globe from the first frame, then the
// site's favicon the host answers (`link.favicons`) in the same square. Sites are asked in one batch
// per render, once each; a site with no icon keeps the globe and is not asked again; a local or
// private address is never asked; GitHub keeps its mark. A prompt's pasted address is a link with
// the same mark, and a fetch tool row shows the page's.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const ICON = "data:image/png;base64,iVBORw0KGgo=";
type Call = { method: string; params: Record<string, unknown> };

async function setup(answer: (hosts: string[]) => Record<string, string>) {
  const { resetSiteIcons } = await import("../src/agent-session/acpmux/chips/siteIcons");
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  resetSiteIcons();
  resetLinkStore();
  const calls: Call[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    if (method === "link.favicons") return { icons: answer(params.hosts as string[]) };
    return undefined;
  });
  return calls;
}

async function render(node: React.ReactNode) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  await act(async () => root.render(<UiProvider container={rootElement}>{node}</UiProvider>));
  // The batch goes out on a microtask and its answer re-renders on another.
  await act(async () => {
    for (let index = 0; index < 5; index++) await Promise.resolve();
  });
  return {
    element: rootElement,
    unmount: () => act(async () => root.unmount()),
  };
}

const favicons = (calls: Call[]) =>
  calls.filter((call) => call.method === "link.favicons").map((call) => call.params.hosts);

beforeEach(async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(undefined);
});

test("a site's host is asked only for a public http(s) address", async () => {
  const { siteIconHost } = await import("../src/agent-session/acpmux/chips/siteIcons");
  expect(siteIconHost("https://Docs.Python.org/3/")).toBe("docs.python.org");
  expect(siteIconHost("http://react.dev")).toBe("react.dev");
  for (const href of [
    "http://localhost:5173/",
    "http://127.0.0.1:47811/?token=x",
    "https://192.168.1.4/",
    "http://printer.local/",
    "http://mymac/",
    "https://[::1]/",
    "mailto:a@b.dev",
    "/Users/you/a.md",
    "not a url",
  ])
    expect(siteIconHost(href)).toBeUndefined();
});

test("links draw the globe, then their site's favicon from one batched ask", async () => {
  const calls = await setup((hosts) =>
    Object.fromEntries(hosts.filter((host) => host !== "nothing.dev").map((host) => [host, ICON])),
  );
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const view = await render(
    <p>
      <UrlChip href="https://react.dev/learn">https://react.dev/learn</UrlChip>
      <UrlChip href="https://react.dev/reference">the reference</UrlChip>
      <UrlChip href="https://docs.python.org/3/">https://docs.python.org/3/</UrlChip>
      <UrlChip href="https://nothing.dev/">https://nothing.dev/</UrlChip>
      <UrlChip href="http://localhost:5173/">http://localhost:5173/</UrlChip>
      <UrlChip href="https://github.com/facebook/react">https://github.com/facebook/react</UrlChip>
    </p>,
  );
  // One ask, each site once; no local address and no GitHub (its own mark).
  expect(favicons(calls)).toEqual([["react.dev", "docs.python.org", "nothing.dev"]]);
  const links = [...view.element.querySelectorAll<HTMLAnchorElement>("a.cv-chip.is-web")];
  const mark = (link: HTMLAnchorElement) => link.querySelector(".cv-site-icon");
  expect(
    links.map((link) => (mark(link)?.querySelector(".cv-site-icon__img") ? "favicon" : mark(link) ? "glyph" : "none")),
  ).toEqual(["favicon", "favicon", "favicon", "glyph", "glyph", "glyph"]);
  expect(mark(links[0]!)!.querySelector<HTMLElement>(".cv-site-icon__img")!.style.backgroundImage).toBe(
    `url("${ICON}")`,
  );
  // No <img>: a copied message carries no icon images for the composer to attach.
  expect(view.element.querySelector("img")).toBeNull();
  // The mark and the text's first characters share one unbreakable lead; the text reads as written.
  const lead = links[0]!.querySelector(".cv-chip__lead")!;
  expect(lead.querySelector(".cv-site-icon")).not.toBeNull();
  expect(lead.textContent).toBe("https://");
  expect(links[0]!.textContent).toBe("https://react.dev/learn");
  expect(links[1]!.querySelector(".cv-chip__lead")!.textContent).toBe("t");
  expect(links[1]!.textContent).toBe("the reference");
  await view.unmount();

  // Drawn again: every answer is kept, the site without an icon too.
  const again = await render(<UrlChip href="https://nothing.dev/x">https://nothing.dev/x</UrlChip>);
  expect(favicons(calls)).toHaveLength(1);
  expect(again.element.querySelector(".cv-site-icon .cv-site-icon__img")).toBeNull();
  await again.unmount();
});

test("a host that cannot answer leaves the globe", async () => {
  const { resetSiteIcons } = await import("../src/agent-session/acpmux/chips/siteIcons");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  resetSiteIcons();
  setChipHost(async () => {
    throw new Error("unsupported");
  });
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const view = await render(<UrlChip href="https://react.dev/">https://react.dev/</UrlChip>);
  expect(view.element.querySelector(".cv-site-icon svg")).not.toBeNull();
  expect(view.element.querySelector(".cv-site-icon .cv-site-icon__img")).toBeNull();
  await view.unmount();
});

test("a prompt's pasted address is a link with its site's mark", async () => {
  const calls = await setup((hosts) => Object.fromEntries(hosts.map((host) => [host, ICON])));
  // The bubble's own path: a prompt holding an address renders through Markdown, whose web links are
  // UrlChip (PromptText.tsx PromptTyped).
  const { PromptTyped } = await import("../src/agent-session/acpmux/conversation/PromptText");
  const view = await render(
    <PromptTyped text="Compare https://react.dev/learn with http://localhost:3000/" show={(text) => text} />,
  );
  const links = [...view.element.querySelectorAll<HTMLAnchorElement>("a.cv-chip.is-web")];
  expect(links.map((link) => link.getAttribute("href"))).toEqual(["https://react.dev/learn", "http://localhost:3000/"]);
  // Only the public site is asked; the local address keeps the globe.
  expect(favicons(calls)).toEqual([["react.dev"]]);
  expect(links[0]!.querySelector(".cv-site-icon .cv-site-icon__img")).not.toBeNull();
  expect(links[1]!.querySelector(".cv-site-icon .cv-site-icon__img")).toBeNull();
  await view.unmount();
});

test("a fetch row shows its page's site mark; a search keeps the globe", async () => {
  const calls = await setup((hosts) => Object.fromEntries(hosts.map((host) => [host, ICON])));
  const { fetchedUrl } = await import("../src/agent-session/acpmux/conversation/ToolSiteIcon");
  const { toolIcon } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  const fetch = {
    kind: "fetch",
    title: "Fetch",
    inputSummary: JSON.stringify({ url: "https://developer.mozilla.org/en-US/docs/Web", prompt: "x" }),
  };
  expect(fetchedUrl(fetch)).toBe("https://developer.mozilla.org/en-US/docs/Web");
  expect(fetchedUrl({ kind: "fetch", title: "Fetch https://react.dev/learn" })).toBe("https://react.dev/learn");
  expect(fetchedUrl({ kind: "fetch", title: "useEffect cleanup" })).toBeUndefined();
  expect(fetchedUrl({ kind: "read", title: "Read https://react.dev/learn" })).toBeUndefined();
  const view = await render(
    <>
      <span className="row">{toolIcon("fetch", fetchedUrl(fetch))}</span>
      <span className="row">{toolIcon("fetch", undefined)}</span>
    </>,
  );
  const [page, search] = [...view.element.querySelectorAll(".row")];
  expect(page!.querySelector(".cv-site-icon--row .cv-site-icon__img")).not.toBeNull();
  expect(search!.querySelector(".cv-site-icon")).toBeNull();
  expect(search!.querySelector("svg")).not.toBeNull();
  expect(favicons(calls)).toEqual([["developer.mozilla.org"]]);
  await view.unmount();
});

test("past the store's limit, sites still being asked get their icons", async () => {
  const calls = await setup((hosts) => Object.fromEntries(hosts.map((host) => [host, ICON])));
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const hosts = Array.from({ length: 513 }, (_, index) => `site${index}.dev`);
  const view = await render(
    <p>
      {hosts.map((host) => (
        <UrlChip key={host} href={`https://${host}/`}>{`https://${host}/`}</UrlChip>
      ))}
    </p>,
  );
  const { act } = await import("react");
  await act(async () => {
    for (let index = 0; index < 100; index++) await Promise.resolve();
  });
  const asked = new Set(favicons(calls).flat());
  for (const host of hosts) expect(asked.has(host)).toBe(true);
  const drawn = view.element.querySelectorAll("a.cv-chip.is-web .cv-site-icon .cv-site-icon__img").length;
  expect(drawn).toBe(hosts.length);
  await view.unmount();
});

test("an answer that is not a base64 PNG data URL is no icon", async () => {
  const sneaky = 'data:image/a"),url("https://x.dev/a.png';
  await setup((hosts) => Object.fromEntries(hosts.map((host) => [host, host === "react.dev" ? sneaky : ICON])));
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const view = await render(
    <p>
      <UrlChip href="https://react.dev/">https://react.dev/</UrlChip>
      <UrlChip href="https://vitejs.dev/">https://vitejs.dev/</UrlChip>
    </p>,
  );
  const marks = [...view.element.querySelectorAll(".cv-site-icon")];
  expect(marks[0]!.querySelector(".cv-site-icon__img")).toBeNull();
  expect(marks[1]!.querySelector(".cv-site-icon__img")).not.toBeNull();
  await view.unmount();
});
