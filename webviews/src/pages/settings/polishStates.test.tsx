// POLISH pass (cx-9br4q): Settings never shows a blank where a list would be, and text it cuts
// short with an ellipsis keeps the whole of it a hover away.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { changeValue, click, renderPage, rowElement } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("Accounts with no accounts says so instead of showing only its buttons", async () => {
  page = await renderPage({
    path: "/settings/accounts",
    setup: (provider) => {
      provider.accounts = { ...provider.accounts, groups: [] };
    },
  });
  expect(page.container.querySelector('[data-card="accounts"]')?.textContent).toContain("No accounts found.");
});

test("Harnesses says it is checking while the first look finds nothing yet", async () => {
  page = await renderPage({
    path: "/settings/agents",
    setup: (provider) => {
      provider.harnesses = { loading: true, problem: null, harnesses: [] };
    },
  });
  expect(page.container.querySelector('[data-card="harnesses"]')?.textContent).toContain("Checking…");
});

test("a theme search that matches nothing says so", async () => {
  page = await renderPage({ path: "/settings/theme" });
  await click(page.container.querySelector('[data-card="theme"] [data-theme-picker]')!);
  await changeValue(document.querySelector<HTMLInputElement>(".theme-search")!, "no such theme anywhere");
  expect(document.querySelector(".theme-popover")?.textContent).toContain("No themes match.");
});

test("a setting's summary and a folder's path show their text with no tooltip repeating it", async () => {
  page = await renderPage({
    path: "/settings/general",
    mock: {
      values: { "agents.chats.roots": ["/opt/user"] },
      chatFolders: [
        { path: "/opt/user", managed: false, reason: null },
        { path: "/Users/test/Documents/chats", managed: true, reason: "This folder is protected." },
      ],
    },
  });
  const summary = page.container.querySelector<HTMLElement>("[data-row-key] .row-help")!;
  // Leo, 2026-10-13: text that shows gets no tooltip, even cut short (test/tooltip-rules.ts).
  expect(summary.title).toBe("");
  const roots = rowElement(page.container, "agents.chats.roots");
  expect(roots.querySelector<HTMLElement>('[data-folder="/opt/user"] .folder-path')?.textContent).toBe("/opt/user");
  expect(roots.querySelector<HTMLElement>('[data-folder="/opt/user"] .folder-path')?.title).toBe("");
  // The refusal is its own line, not clipped inside the one-line path.
  expect(roots.querySelector(".folder-path .row-error")).toBeNull();
  expect(roots.textContent).toContain("This folder is protected.");
});
