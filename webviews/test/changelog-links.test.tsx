import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

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

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("grouped What's New entries keep readable summaries and expose their docs links", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Groups } = await import("../src/pages/changelog/ReleaseParts");
  const { releaseView } = await import("../src/pages/changelog/model");
  const notes = {
    build: "1",
    shortVersion: "1.0.0-nightly.1",
    date: "2026-10-16",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.1",
      channel: "nightly" as const,
      date: "2026-10-16",
      headline: { en: "A clearer update" },
      entries: [
        {
          id: "groups",
          category: "new" as const,
          title: { en: "Workspace groups" },
          summary: { en: "Keep related workspaces together so the sidebar is easier to scan." },
          docs: "https://cmux.com/docs/sidebar",
        },
      ],
    },
  };
  const strings = {
    language: "en",
    t: (key: string) =>
      ({
        "changelog.group.new": "New",
        "changelog.page.learnMore": "Learn more",
        "changelog.page.tryIt": "Try it",
      })[key] ?? key,
    format: (key: string, ...args: string[]) => `${key} ${args.join(" ")}`,
  };
  const root = createRoot(host);
  const view = releaseView(notes, "en");
  act(() => root.render(<Groups view={view} ctx={{ strings, onTry: () => undefined }} />));

  const row = host.querySelector(".cl-group li")!;
  expect(row.querySelector(".cl-row-title")?.textContent).toBe("Workspace groups");
  expect(row.querySelector(".cl-row-summary")?.textContent).toContain("easier to scan");
  const link = row.querySelector<HTMLAnchorElement>(".cl-row-link")!;
  expect(link.href).toBe("https://cmux.com/docs/sidebar");
  expect(link.textContent).toBe("Learn more");
  expect(link.getAttribute("aria-label")).toBe("Learn more: Workspace groups");
  act(() => root.unmount());
});

test("the Digest design shows each change's docs link under its summary", async () => {
  const { createRoot } = await import("react-dom/client");
  const { DigestPage } = await import("../src/pages/changelog/DigestPage");
  const notes = {
    build: "1",
    shortVersion: "1.0.0-nightly.1",
    date: "2026-10-16",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.1",
      channel: "nightly" as const,
      date: "2026-10-16",
      headline: { en: "A clearer update" },
      entries: [
        {
          id: "groups",
          category: "new" as const,
          title: { en: "Workspace groups" },
          summary: { en: "Keep related workspaces together so the sidebar is easier to scan." },
          docs: "https://cmux.com/docs/sidebar",
        },
      ],
    },
  };
  const strings = {
    language: "en",
    t: (key: string) =>
      ({
        "changelog.group.new": "New",
        "changelog.page.learnMore": "Learn more",
        "changelog.page.title": "What's New",
      })[key] ?? key,
    format: (key: string, ...args: string[]) => `${key} ${args.join(" ")}`,
  };
  const snapshot = {
    builds: [{ build: "1", shortVersion: "1.0.0-nightly.1", date: "2026-10-16", highlights: 1 }],
    loading: false,
    missing: false,
    inSpan: [],
    loaded: { "1": notes },
    unavailable: {},
  };
  const store = { tryIt: async () => undefined, ensure: async () => undefined };
  const root = createRoot(host);
  act(() =>
    root.render(
      <DigestPage
        store={store as unknown as Parameters<typeof DigestPage>[0]["store"]}
        strings={strings as unknown as Parameters<typeof DigestPage>[0]["strings"]}
        s={snapshot as unknown as Parameters<typeof DigestPage>[0]["s"]}
      />,
    ),
  );

  const item = host.querySelector(".cld-item")!;
  expect(item.querySelector(".cl-row-summary")?.textContent).toContain("easier to scan");
  const link = item.querySelector<HTMLAnchorElement>(".cl-row-link")!;
  expect(link.href).toBe("https://cmux.com/docs/sidebar");
  expect(link.getAttribute("aria-label")).toBe("Learn more: Workspace groups");
  // Digest stacks each change in a column, so its actions stay visible instead of revealing on hover.
  const style = host.ownerDocument.createElement("style");
  style.textContent = await Bun.file(new URL("../src/pages/changelog/styles.css", import.meta.url)).text();
  host.ownerDocument.head.append(style);
  const actions = item.querySelector<HTMLElement>(".cl-row-actions")!;
  expect(host.ownerDocument.defaultView!.getComputedStyle(actions).opacity).toBe("1");
  style.remove();
  act(() => root.unmount());
});

test("the Ledger design keeps a change's actions on its row, not on a blank line under it", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Groups } = await import("../src/pages/changelog/ReleaseParts");
  const { releaseView } = await import("../src/pages/changelog/model");
  const entry = {
    id: "groups",
    category: "new" as const,
    title: { en: "Workspace groups" },
    summary: { en: "Keep related workspaces together." },
    docs: "https://cmux.com/docs/sidebar",
  };
  const notes = {
    build: "1",
    shortVersion: "1.0.0-nightly.1",
    date: "2026-10-16",
    highlights: [],
    changes: [],
    whatsNew: {
      version: "1.0.0-nightly.1",
      channel: "nightly" as const,
      date: "2026-10-16",
      headline: { en: "x" },
      entries: [entry],
    },
  };
  const strings = { language: "en", t: (key: string) => key, format: (key: string) => key };
  const style = host.ownerDocument.createElement("style");
  style.textContent = await Bun.file(new URL("../src/pages/changelog/styles.css", import.meta.url)).text();
  host.ownerDocument.head.append(style);
  const root = createRoot(host);
  act(() =>
    root.render(
      <div className="cll">
        <Groups view={releaseView(notes, "en")} ctx={{ strings, onTry: () => undefined, rowMedia: true }} />
      </div>,
    ),
  );
  // The Ledger's actions end the row's last line; a block-level actions box would add an empty line under each.
  const actions = host.querySelector<HTMLElement>(".cl-group li .cl-row-actions")!;
  expect(host.ownerDocument.defaultView!.getComputedStyle(actions).display).toBe("inline-flex");
  expect(actions.parentElement?.classList.contains("cl-row-summary")).toBe(true);
  style.remove();
  act(() => root.unmount());
});
