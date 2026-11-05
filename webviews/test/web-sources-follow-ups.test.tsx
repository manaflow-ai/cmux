// l10n-allow-file: test fixtures (a web search's result in Claude Code's words), not shipped UI.
// Codex review of #36386 (the web search sources chip), follow-ups F2 and F3: in a read-only
// transcript a source opens as a plain link in the reader's browser, never through the owner's
// host; and Find in Chat reads a search's result without the links line the chip took over.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { activityText } from "../src/agent-session/acpmux/conversation/chatFind";
import { webSources } from "../src/agent-session/acpmux/conversation/webSourceList";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

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
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const SEARCH = [
  'Web search results for query: "t3code"',
  "",
  'Links: [{"title":"t3code","url":"https://github.com/pingdotgg/t3code"}]',
  "",
  "T3 Code is a desktop app.",
].join("\n");

const search: AcpmuxActivity = {
  kind: "tool",
  text: "Search",
  tool: { id: "s", title: "t3code", kind: "fetch", status: "completed", output: SEARCH },
};

async function openSources(readOnly: boolean): Promise<HTMLAnchorElement> {
  const { createRoot } = await import("react-dom/client");
  const { WebSources } = await import("../src/agent-session/acpmux/conversation/WebSources");
  const { TranscriptReadOnly } = await import("../src/agent-session/acpmux/conversation/readOnly");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <TranscriptReadOnly.Provider value={readOnly}>
        <WebSources sources={webSources(search.tool)} />
      </TranscriptReadOnly.Provider>,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>(".cv-web-sources__chip")!.click());
  return host.querySelector<HTMLAnchorElement>(".cv-web-sources__page")!;
}

test("a read-only transcript's source is a plain link to the reader's browser", async () => {
  const page = await openSources(true);
  expect(page.getAttribute("href")).toBe("https://github.com/pingdotgg/t3code");
  expect(page.getAttribute("target")).toBe("_blank");
  expect(page.getAttribute("rel")).toBe("noopener noreferrer");
});

test("the owner's transcript opens a source in a cmux tab, not a new window", async () => {
  expect((await openSources(false)).getAttribute("target")).toBeNull();
});

test("Find reads a search's result without the links line", () => {
  const text = activityText(search);
  expect(text).toContain("T3 Code is a desktop app.");
  expect(text).not.toContain("Links:");
});
