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
