// l10n-allow-file: test fixture addresses, not shipped UI.
// Leo 2026-10-20, "did we fix this bullshit yet": an agent's bare http://127.0.0.1:47811?token=… drew a
// full-width card (globe, the raw address with its token, Open in tab, Open in, then a ~300px empty
// see-through box around Load preview). A link in a reply now reads as text: no globe, a secret
// query value as •••, the real href kept; a site's title and favicon only in the hover card; a local
// or private address never dressed as a site; the turn's preview card only behind the Debug toggle
// agentPane.debug.turnPreviewCards, and opaque.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
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

const TOKEN_URL = "http://127.0.0.1:47811?token=ad27875be63b0aa1c1ea76c048581e181e470bc39a1c71be";
const webviews = path.join(import.meta.dir, "..");

test("secret-looking query values read as •••; other parameters and the rest stay as written", async () => {
  const { redactUrlText, isSecretParam } = await import("../src/agent-session/acpmux/chips/linkDisplay");
  expect(redactUrlText(TOKEN_URL)).toBe("http://127.0.0.1:47811?token=•••");
  expect(redactUrlText("https://example.test/cb?code=abc123&state=xyz")).toBe(
    "https://example.test/cb?code=•••&state=xyz",
  );
  expect(redactUrlText("https://s3.example.test/a.png?X-Amz-Signature=deadbeef&X-Amz-Date=1")).toBe(
    "https://s3.example.test/a.png?X-Amz-Signature=•••&X-Amz-Date=1",
  );
  expect(redactUrlText("https://api.example.test/v1?api_key=k1&page=2#access_token=t1")).toBe(
    "https://api.example.test/v1?api_key=•••&page=2#access_token=•••",
  );
  expect(redactUrlText("https://user:hunter2@example.test/x")).toBe("https://user:•••@example.test/x");
  expect(redactUrlText("https://example.test/search?q=token&sort=new")).toBe(
    "https://example.test/search?q=token&sort=new",
  );
  expect(redactUrlText("https://example.test/docs")).toBe("https://example.test/docs");
  for (const name of ["token", "auth", "sig", "password", "secret", "client_secret", "apiKey", "key", "code"])
    expect(isSecretParam(name)).toBe(true);
  for (const name of ["sessionid", "PHPSESSID", "hmac", "accessToken", "clientSecret", "privateKey", "authcode"])
    expect(isSecretParam(name)).toBe(true);
  for (const name of ["q", "page", "keyboard", "sort", "entry", "tab", "tokenizer"])
    expect(isSecretParam(name)).toBe(false);
});

test("local and private addresses are recognized", async () => {
  const { isPrivateUrl } = await import("../src/agent-session/acpmux/chips/linkDisplay");
  for (const url of [
    TOKEN_URL,
    "http://localhost:5173/",
    "http://app.localhost/",
    "http://0.0.0.0:8080",
    "http://10.0.0.4/",
    "http://192.168.1.20:3000/x",
    "http://172.20.1.1/",
    "http://169.254.1.1/",
    "http://printer.local/",
    "http://[::1]:3000/",
    "http://100.101.102.103:7000/",
    "http://localhost./",
    "http://[::ffff:127.0.0.1]:3000/",
    "http://host.docker.internal/",
    "http://mymac:3000/",
  ])
    expect(isPrivateUrl(url)).toBe(true);
  for (const url of [
    "https://example.com/",
    "http://172.32.0.1/",
    "http://[::ffff:8.8.8.8]/",
    "mailto:a@b.test",
    "https://github.com/o/r",
    "not a url",
  ])
    expect(isPrivateUrl(url)).toBe(false);
});

async function renderChip(
  href: string,
  children: string,
  sites: Record<string, { title?: string; icon?: string }> = {},
) {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { seedLinkStore, resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  resetLinkStore();
  seedLinkStore({ sites });
  setChipHost(async () => undefined);
  await act(async () => {
    root.render(
      <UiProvider container={rootElement}>
        <UrlChip href={href}>{children}</UrlChip>
      </UiProvider>,
    );
  });
  const link = rootElement.querySelector<HTMLAnchorElement>("a.cv-chip")!;
  return {
    link,
    rootElement,
    async hover() {
      await act(async () => link.focus());
      return rootElement.querySelector<HTMLElement>(".cv-link-preview")!;
    },
    async done() {
      await act(async () => root.unmount());
      setChipHost(undefined);
      resetLinkStore();
    },
  };
}

const FAVICON = "data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%2F%3E";

test("a bare address with a token reads as plain link text: no icon, the token masked, the href real", async () => {
  // A site title cmux browsed on that port changes nothing: a local address is never dressed as a site.
  const chip = await renderChip(TOKEN_URL, TOKEN_URL, { [TOKEN_URL]: { title: "Dev server", icon: FAVICON } });
  expect(chip.link.getAttribute("href")).toBe(TOKEN_URL);
  expect(chip.link.textContent).toBe("http://127.0.0.1:47811?token=•••");
  expect(chip.link.querySelector("svg, img")).toBeNull();
  const card = await chip.hover();
  expect(card.textContent).not.toContain("ad27875be63b");
  expect(card.textContent).toContain("token=•••");
  // Hover actions: Open (a cmux tab) and Open in ▾.
  expect(card.querySelector(".cv-link-preview__open")).not.toBeNull();
  expect(card.querySelector(".acpmux-open-in")).not.toBeNull();
  await chip.done();
});

test("a web address with no title cmux knows is plain link text, no globe", async () => {
  const chip = await renderChip("https://example.test/docs", "https://example.test/docs");
  expect(chip.link.querySelector("svg, img")).toBeNull();
  expect(chip.link.textContent).toBe("https://example.test/docs");
  await chip.done();
});

// Leo 2026-10-21: "[#22896](…/pull/22896)" grew into "#22896 · cmux-next updates: pulled-build banner
// (…)" once its page title came in, and the paragraph reflowed under him. A chip's text and icon are
// fixed when it first draws; the title and the favicon live in the hover card.
const PR_HREF = "https://github.com/manaflow-ai/cmux/pull/22896";
const PR_PAGE_TITLE =
  "cmux-next updates: pulled-build banner (staged) by teamleaderleo · Pull Request #22896 · manaflow-ai/cmux · GitHub";

async function seedLater(sites: Record<string, { title?: string; icon?: string }>) {
  const { act } = await import("react");
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  await act(async () => {
    seedLinkStore({ sites });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

test("a pull request chip keeps its text when the pull request's title comes in; the title is in the card", async () => {
  const chip = await renderChip(PR_HREF, "#22896");
  const before = chip.link.innerHTML;
  expect(chip.link.textContent).toBe("#22896");
  await seedLater({ [PR_HREF]: { title: PR_PAGE_TITLE, icon: FAVICON } });
  expect(chip.link.textContent).toBe("#22896");
  expect(chip.link.innerHTML).toBe(before);
  expect(chip.link.querySelector(".cv-chip__title, img")).toBeNull();
  const card = await chip.hover();
  expect(card.querySelector(".cv-link-preview__site")?.textContent).toBe(
    "cmux-next updates: pulled-build banner (staged)",
  );
  // Hovering changes nothing in the line either.
  expect(chip.link.textContent).toBe("#22896");
  await chip.done();
});

test("a pull request chip whose title cmux already has draws the same as one it has no title for", async () => {
  const chip = await renderChip(PR_HREF, "#22896", { [PR_HREF]: { title: PR_PAGE_TITLE, icon: FAVICON } });
  expect(chip.link.textContent).toBe("#22896");
  expect(chip.link.querySelector(".cv-chip__title, img")).toBeNull();
  expect(chip.link.querySelector("svg")).not.toBeNull();
  await chip.done();
});

test("a bare address keeps its text and draws no favicon when the site's title and icon come in", async () => {
  const href = "https://docs.example.test/guide";
  const chip = await renderChip(href, href);
  const before = chip.link.innerHTML;
  await seedLater({ [href]: { title: "Example docs", icon: FAVICON } });
  expect(chip.link.textContent).toBe(href);
  expect(chip.link.innerHTML).toBe(before);
  expect(chip.link.querySelector("svg, img")).toBeNull();
  const card = await chip.hover();
  expect(card.querySelector(".cv-link-preview__site")?.textContent).toBe("Example docs");
  expect(card.querySelector(".cv-link-preview__icon img")?.getAttribute("src")).toBe(FAVICON);
  await chip.done();
});

test("a site cmux already has a title for still reads as its address; the card has the favicon and title", async () => {
  const href = "https://docs.example.test/guide";
  const chip = await renderChip(href, href, { [href]: { title: "Example docs", icon: FAVICON } });
  expect(chip.link.textContent).toBe(href);
  expect(chip.link.querySelector("svg, img")).toBeNull();
  const card = await chip.hover();
  expect(card.querySelector(".cv-link-preview__site")?.textContent).toBe("Example docs");
  expect(card.querySelector(".cv-link-preview__icon img")?.getAttribute("src")).toBe(FAVICON);
  await chip.done();
});

test("a turn's preview card shows only behind the Debug toggle agentPane.debug.turnPreviewCards", async () => {
  const { turnView, PREVIEW } = await import("../src/agent-session/acpmux/conversation/turns");
  // Fresh rows each time: a turn view is cached by its rows.
  const rows = () =>
    [
      { id: "u1", kind: "user", text: "Start it", at: 1_000 },
      { id: "a1", kind: "assistant", text: `It runs at ${TOKEN_URL}`, at: 2_000 },
      { id: "s1", kind: "turnSummary", status: "completed", at: 2_000 },
    ] as never;
  const root = dom.window.document.documentElement;
  delete root.dataset.turnPreviewCards;
  expect(turnView(rows(), new Set()).some((row) => row.kind === PREVIEW)).toBe(false);
  root.dataset.turnPreviewCards = "on";
  try {
    expect(turnView(rows(), new Set()).some((row) => row.kind === PREVIEW)).toBe(true);
  } finally {
    delete root.dataset.turnPreviewCards;
  }
});

test("the preview card masks its address's secrets and draws on an opaque surface", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { PreviewCard } = await import("../src/agent-session/acpmux/conversation/PreviewCard");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  await act(async () => root.render(<PreviewCard url={TOKEN_URL} onOpen={() => {}} />));
  const address = rootElement.querySelector(".acpmux-turn-preview-address")!;
  expect(address.textContent).toContain("token=•••");
  expect(address.textContent).not.toContain("ad27875be63b");
  expect(address.getAttribute("href")).toBe(TOKEN_URL);
  await act(async () => root.unmount());
  // The page's own background is transparent over art or a see-through window, so the card and
  // its frame sit on the theme's solid surface.
  const styles = readFileSync(path.join(webviews, "src/agent-session/acpmux/styles.css"), "utf8");
  const rule = (selector: string) => new RegExp(`\\${selector}\\{[^}]*\\}`).exec(styles)?.[0] ?? "";
  for (const selector of [".acpmux-turn-preview", ".acpmux-turn-preview-frame"])
    expect(rule(selector)).toContain("var(--cmux-surface-solid");
});

test("a web card's head names the site; its address shows only when it says more than the host", async () => {
  const root = await renderChip("https://example.test/", "https://example.test/");
  const rootCard = await root.hover();
  expect(rootCard.querySelector(".cv-link-preview__site")?.textContent).toBe("example.test");
  expect(rootCard.querySelector(".cv-link-preview__target")).toBeNull();
  await root.done();
  const deep = await renderChip("https://example.test/docs/start", "https://example.test/docs/start");
  const deepCard = await deep.hover();
  expect(deepCard.querySelector(".cv-link-preview__site")?.textContent).toBe("example.test");
  expect(deepCard.querySelector(".cv-link-preview__target")?.textContent).toBe("https://example.test/docs/start");
  // No "host · address" footer: the address sits under the title, inside the head.
  expect(deepCard.querySelector(".cv-link-preview__head .cv-link-preview__target")).not.toBeNull();
  await deep.done();
});

test("path locality is hover text, with no persistent lock; open and text-only policies stay intact", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { PathChip, ElsewhereChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { seedLinkStore, resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const strings = (await import("../src/agent-session/acpmux/generated/strings.json")).default;
  const savedStrings = globalThis.__cmuxPaneStrings;
  globalThis.__cmuxPaneStrings = strings;
  const outside = "/tmp/example/cmux.json";
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const calls: unknown[] = [];
  resetLinkStore();
  seedLinkStore({ paths: { [outside]: { place: "outside", folder: false } } });
  setChipHost(async (method, params) => {
    calls.push({ method, params });
  });
  try {
    await act(async () =>
      root.render(
        <>
          <PathChip path={outside} label="cmux.json" />
          <ElsewhereChip path={outside} host="example-host" />
        </>,
      ),
    );
    const chip = rootElement.querySelector<HTMLButtonElement>("button.is-path")!;
    expect(chip.textContent).toBe("cmux.json");
    expect(chip.getAttribute("title")).toBe(`Outside this project\n${outside}`);
    expect(rootElement.querySelector(".cv-chip__lock")).toBeNull();
    expect(rootElement.querySelector(".is-elsewhere")?.getAttribute("title")).toBe(`On example-host: ${outside}`);
    expect(rootElement.querySelector(".is-elsewhere")?.tagName).toBe("SPAN");
    await act(async () => chip.click());
    expect(calls).toEqual([{ method: "link.openPath", params: { path: outside } }]);
    await act(async () => seedLinkStore({ policy: { outsideRoots: "text" } }));
    expect(rootElement.querySelector("button")).toBeNull();
    expect(rootElement.querySelector(".cv-chip-plain")?.textContent).toBe("cmux.json");
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
    resetLinkStore();
    globalThis.__cmuxPaneStrings = savedStrings;
  }
});
