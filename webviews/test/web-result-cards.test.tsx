// l10n-allow-file: test fixtures (web search and fetch results in Claude Code's words), not shipped UI.
// Web search and fetch rows as result cards (WebSources.tsx). Leo, 2026-11-08: "The little minor
// things where it's like, oh, f***. Like, just because of this, I'm out." Before: a search's chip
// and list drew a globe for every site, and a fetch drew a "Sources" chip that opened to its one
// page. Now each site shows the icon cmux has for it in a fixed slot, and a fetch is one link card.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { resetLinkStore, seedLinkStore } from "../src/agent-session/acpmux/chips/linkStore";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { fetchedPage, webSources } from "../src/agent-session/acpmux/conversation/webSourceList";
import { teardownDom } from "./support/domTeardown";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const calls: { method: string; params: Record<string, unknown> }[] = [];

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return {};
  });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  calls.length = 0;
  resetLinkStore();
});

afterAll(async () => {
  setChipHost(undefined);
  await teardownDom(saved, { scope });
});

const SEARCH = [
  'Web search results for query: "t3code"',
  "",
  'Links: [{"title":"t3code","url":"https://github.com/pingdotgg/t3code"},{"title":"Repowise","url":"https://repowise.dev/repo/t3code"}]',
  "",
  "T3 Code is a desktop app.",
].join("\n");

const call = (extra: Partial<Tool>): Tool =>
  ({ id: "w", title: "t3code", kind: "fetch", status: "completed", ...extra }) as Tool;

async function draw(tool: Tool) {
  const { createRoot } = await import("react-dom/client");
  const { WebSources } = await import("../src/agent-session/acpmux/conversation/WebSources");
  root = createRoot(host);
  await act(async () => root!.render(<WebSources sources={webSources(tool)} fetched={fetchedPage(tool)} />));
}

test("a fetch is one link card: the site's icon, the page's title, its site, and no list", async () => {
  const url = "https://docs.example.com/en/docs/claude-code/hooks";
  seedLinkStore({ sites: { [url]: { icon: "data:image/png;base64,AA==", title: "Hooks reference" } } });
  await draw(call({ title: `Fetch ${url}`, output: "# Hooks" }));
  const card = host.querySelector<HTMLAnchorElement>("a.cv-web-sources__card")!;
  expect(card.getAttribute("href")).toBe(url);
  expect(card.querySelector(".cv-web-sources__title")?.textContent).toBe("Hooks reference");
  expect(card.querySelector(".cv-web-sources__site")?.textContent).toBe("docs.example.com");
  expect(card.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AA==");
  expect(host.querySelector("button.cv-web-sources__chip")).toBeNull();
  await act(async () => card.click());
  expect(calls.find((sent) => sent.method === "browser.openIn")?.params).toEqual({ url, browserId: "cmux" });
});

test("a fetch cmux knows nothing about reads where its page sits, with the globe in the icon slot", async () => {
  await draw(call({ title: "Fetch https://docs.example.com/en/docs/claude-code/hooks", output: "# Hooks" }));
  const card = host.querySelector<HTMLAnchorElement>("a.cv-web-sources__card")!;
  expect(card.querySelector(".cv-web-sources__title")?.textContent).toBe("claude-code/hooks");
  expect(card.querySelector(".cv-web-sources__icon img")).toBeNull();
  expect(card.querySelector(".cv-web-sources__icon svg")).not.toBeNull();
});

test("a search's chip and its list show each site's icon, the globe where cmux has none", async () => {
  seedLinkStore({ sites: { "https://github.com/pingdotgg/t3code": { icon: "data:image/png;base64,GH==" } } });
  await draw(call({ output: SEARCH }));
  const chip = host.querySelector<HTMLButtonElement>("button.cv-web-sources__chip")!;
  const named = [...chip.querySelectorAll(".cv-web-sources__named")];
  expect(named.map((site) => site.textContent)).toEqual(["github.com", "repowise.dev"]);
  expect(named[0].querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,GH==");
  expect(named[1].querySelector("img")).toBeNull();
  await act(async () => chip.click());
  const rows = [...host.querySelectorAll<HTMLAnchorElement>(".cv-web-sources__page")];
  expect(rows.map((row) => row.querySelector(".cv-web-sources__title")?.textContent)).toEqual(["t3code", "Repowise"]);
  expect(rows.every((row) => row.querySelector(".cv-web-sources__icon"))).toBe(true);
});

test("a running fetch draws nothing under its row", async () => {
  await draw(call({ title: "Fetch https://example.com/a", status: "in_progress" }));
  expect(host.querySelector(".cv-web-sources")).toBeNull();
});
