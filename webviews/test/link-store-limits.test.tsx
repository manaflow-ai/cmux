// Codex review of #38414, F1: the host refuses a whole `link.inspect` when one URL is past its
// 2048-byte limit (AgentPaneReplyRequest.swift `maximumURL`), so one oversized link in a web search
// left every other source and reply link without its icon or title. Before: the oversized URL was
// sent with the rest. Now it is answered on the page as one the host has nothing for.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { resetLinkStore, useSiteInfo, usePathInfo } from "../src/agent-session/acpmux/chips/linkStore";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const sent: { urls: string[]; paths: string[] }[] = [];

const LONG = `https://example.com/${"a".repeat(2100)}`;
const OK = "https://example.com/ok";
const LONG_PATH = `/work/${"p".repeat(4100)}`;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
  // Stands in for the host's contract: any entry past its limit refuses the whole call.
  setChipHost(async (method, params) => {
    if (method !== "link.inspect") return null;
    const urls = (params.urls as string[]) ?? [];
    const paths = (params.paths as string[]) ?? [];
    sent.push({ urls, paths });
    if (urls.some((url) => url.length > 2048) || paths.some((path) => path.length > 4096)) return null;
    return { sites: Object.fromEntries(urls.map((url) => [url, { title: `title of ${url}` }])) };
  });
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  sent.length = 0;
  resetLinkStore();
});

afterAll(async () => {
  setChipHost(undefined);
  await teardownDom(saved, { scope });
});

function Probe({ url }: { url: string }) {
  return <span data-url={url}>{useSiteInfo(url)?.title ?? "none"}</span>;
}

function PathProbe({ path }: { path: string }) {
  const { answered } = usePathInfo(path);
  return <span data-path>{answered ? "answered" : "asking"}</span>;
}

test("an oversized URL is never sent, and the rest of its batch still gets answers", async () => {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <>
        <Probe url={LONG} />
        <Probe url={OK} />
      </>,
    ),
  );
  await act(async () => undefined);
  expect(sent.flatMap((call) => call.urls)).toEqual([OK]);
  expect(host.querySelector(`[data-url="${OK}"]`)?.textContent).toBe(`title of ${OK}`);
  expect(host.querySelector(`[data-url="${LONG}"]`)?.textContent).toBe("none");
});

test("an oversized path is answered on the page, never sent", async () => {
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  await act(async () => root!.render(<PathProbe path={LONG_PATH} />));
  await act(async () => undefined);
  expect(sent.flatMap((call) => call.paths)).toEqual([]);
  expect(host.querySelector("[data-path]")?.textContent).toBe("answered");
});
