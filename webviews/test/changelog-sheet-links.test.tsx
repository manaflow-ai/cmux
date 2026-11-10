// The What's New sheet links a change to its public pull request and shows its whole description
// (Leo 2026-11-07: "this could maybe still be better with linking to prs... or not necessarily
// actually since we have some in private? hm. ... i just still think it might be a bit too narrow
// in the full screen"). A change from a private repository shows no link, name or number.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const entry = (id: string, title: string, summary: string, pr?: string) => ({
  id,
  category: "new" as const,
  title: { en: title },
  summary: { en: summary },
  ...(pr ? { pr } : {}),
});

const notes = {
  build: "1",
  shortVersion: "1.0.0-nightly.1",
  date: "2026-11-07",
  highlights: [],
  changes: [],
  items: [{ title: "Sidebar rows keep their place when a workspace closes", pr: 37001 }],
  whatsNew: {
    version: "1.0.0-nightly.1",
    channel: "nightly" as const,
    date: "2026-11-07",
    headline: { en: "x" },
    entries: [
      entry(
        "public",
        "Archive sidebar workspaces",
        "Right-click a workspace and choose Archive. Unarchive puts it back where it was.",
        "https://github.com/manaflow-ai/cmux/pull/36001",
      ),
      entry(
        "private",
        "Cloud machines start faster",
        "A new machine is ready in seconds.",
        "https://github.com/manaflow-ai/cmux-platform/pull/512",
      ),
      entry("by-title", "Sidebar rows keep their place when a workspace closes", "Nothing jumps."),
    ],
  },
};

const strings = { language: "en", t: (key: string) => key, format: (key: string) => key };

test("sheet rows link public cmux pull requests only and keep the whole description", async () => {
  const { sheetRows } = await import("../src/pages/changelog/SheetPage");
  const { releaseView } = await import("../src/pages/changelog/model");
  const rows = sheetRows(releaseView(notes, "en"));
  const byTitle = Object.fromEntries(rows.map((r) => [r.title, r]));
  expect(byTitle["Archive sidebar workspaces"]?.pr).toBe(36001);
  expect(byTitle["Archive sidebar workspaces"]?.line).toBe(
    "Right-click a workspace and choose Archive. Unarchive puts it back where it was.",
  );
  expect(byTitle["Cloud machines start faster"]?.pr).toBeUndefined();
  expect(byTitle["Sidebar rows keep their place when a workspace closes"]?.pr).toBe(37001);
});

test("the sheet draws a public row's title as its pull request link and a private row as text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { SheetPage } = await import("../src/pages/changelog/SheetPage");
  const s = {
    builds: [{ build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-11-07", highlights: 3 }],
    loading: false,
    missing: false,
    inSpan: [],
    loaded: { "1": notes },
    unavailable: {},
    installs: false,
  };
  const root = createRoot(host);
  try {
    act(() => root.render(<SheetPage store={{} as never} strings={strings as never} s={s as never} links="hover" />));
    expect(host.querySelector(".cls")?.classList.contains("cls-prs-hover")).toBe(true);
    const links = [...host.querySelectorAll<HTMLAnchorElement>("a.cls-row-link")];
    expect(links.map((a) => a.getAttribute("href") ?? "").sort((a, b) => a.localeCompare(b))).toEqual([
      "https://github.com/manaflow-ai/cmux/pull/36001",
      "https://github.com/manaflow-ai/cmux/pull/37001",
    ]);
    expect(host.textContent).not.toContain("cmux-platform");
    expect(host.textContent).not.toContain("#512");
    expect(
      [...host.querySelectorAll(".cls-row-pr")].map((n) => n.textContent ?? "").sort((a, b) => a.localeCompare(b)),
    ).toEqual(["#36001", "#37001"]);
    const privateRow = [...host.querySelectorAll(".cls-row")].find((r) => r.textContent?.includes("Cloud machines"));
    expect(privateRow?.querySelector("a")).toBeNull();
  } finally {
    act(() => root.unmount());
  }
});

test("the shared PR chip leaves a private repository's pull request as plain text", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChangePullRequest } = await import("../src/pages/changelog/ChangePullRequest");
  const root = createRoot(host);
  try {
    act(() =>
      root.render(<ChangePullRequest pr="https://github.com/manaflow-ai/cmux-platform/pull/512" title="Private" />),
    );
    expect(host.textContent).toBe("Private");
    expect(host.querySelector("a")).toBeNull();
  } finally {
    act(() => root.unmount());
  }
});

test("a raw change's row shows its description's first paragraph, not the paragraphs after it", async () => {
  const { sheetRows } = await import("../src/pages/changelog/SheetPage");
  const { releaseView } = await import("../src/pages/changelog/model");
  const raw = {
    build: "2",
    shortVersion: "1.0.0-nightly.2",
    date: "2026-11-07",
    highlights: [],
    changes: [],
    items: [
      {
        title: "Sidebar rows keep their place when a workspace closes",
        pr: 37002,
        description:
          "Nothing jumps when a row goes.\nIts neighbours stay put.\n\nThe store now keeps a tombstone per row.",
      },
    ],
  };
  const rows = sheetRows(releaseView(raw, "en"));
  expect(rows.map((r) => r.line)).toEqual(["Nothing jumps when a row goes. Its neighbours stay put."]);
});
