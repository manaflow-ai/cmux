// l10n-allow-file: test fixtures.
// What's New lists every change of the update by area (whats-new lane, 2026-10-20): the page
// folded the span's changes into one flat "All changes" list, said "Maintenance and fixes" over a
// span with no curated lines even when it had user-visible commits, and kept internal work as a
// bare count ("2 internal changes"). Now the span's changes are open, grouped by area ("Sidebar",
// "Composer", then "Other"), each with its pull request, and internal work is listed, with its pull
// requests, under a collapsed "Under the hood". An update with curated notes folds them under its lead
// changes and cards (whats-new-happy-news.test.tsx); this one has none, so its changes stay open.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    url: "cmux-page://cmux.changelog/#/?design=ledger&from=1.0.0-nightly.3940000000001&to=1.0.0-nightly.3940000000003",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    location: dom.window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function notes(build: string, items: { title: string; pr: number }[]) {
  return {
    build,
    shortVersion: `1.0.0-nightly.${build}`,
    date: "2026-10-20",
    highlights: [],
    changes: items.map((i) => `${i.title} (#${i.pr})`),
    items,
  };
}

// Two nightlies after the installed one (…001), newest first; neither has curated lines.
const span = [
  notes("3940000000003", [
    { title: "cmux-next sidebar: groups made by automation take a palette color", pr: 201 },
    { title: "cmux NEXT composer: Return steers a running turn", pr: 202 },
    { title: "ci: shard the gallery capture", pr: 203 },
  ]),
  notes("3940000000002", [
    { title: "cmux-next sidebar: a click never drags", pr: 301 },
    { title: "fix(cmux-next): enroll Computer Use after peer check", pr: 302 },
    { title: "test(next sidebar): the focus-loss drag test calls pointerFocusLost", pr: 303 },
  ]),
  notes("3940000000001", [{ title: "cmux-next tabs: the installed build's change", pr: 101 }]),
];

const pull = (n: number) => `https://github.com/manaflow-ai/cmux/pull/${n}`;
const rows = (list: Element | null | undefined) =>
  [...(list?.querySelectorAll(":scope > li") ?? [])].map((li) => [
    li.querySelector("span")?.textContent,
    li.querySelector<HTMLAnchorElement>("a.cl-pr")?.href,
  ]);

test("What's New lists the update's changes by area with their pull requests, internal work under the hood", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  // The span's notes load after the list: yield until the section is drawn and every call is answered.
  let open = 0;
  class Counted extends MockChangelogProvider {
    override async call<R>(op: string, params: unknown): Promise<R> {
      open += 1;
      try {
        return await super.call<R>(op, params);
      } finally {
        open -= 1;
      }
    }
  }
  await act(async () => {
    mountChangelogPage(root, new Counted(span, "3940000000003") as never);
  });
  const deadline = performance.now() + 2_000;
  do {
    if (performance.now() > deadline) throw new Error("timed out waiting for the update's notes");
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  } while (open > 0 || !root.querySelector('[data-testid="changelog.sinceLastUpdate"] .cl-area'));
  const section = root.querySelector('[data-testid="changelog.sinceLastUpdate"]');
  expect(section).not.toBeNull();
  // The span has user-visible changes: never "Maintenance and fixes" over them.
  expect(section?.querySelector(".cl-maintenance")).toBeNull();
  // No curated notes: the changes are the news, so they are open.
  const fold = section?.querySelector<HTMLDetailsElement>("details.cl-changes");
  expect(fold?.open).toBe(true);
  const areas = [...(fold?.querySelectorAll(".cl-area") ?? [])];
  expect(areas.map((a) => a.querySelector("h4")?.textContent)).toEqual(["Sidebar", "Composer", "Other"]);
  expect(rows(areas[0]?.querySelector("ul"))).toEqual([
    ["Groups made by automation take a palette color", pull(201)],
    ["A click never drags", pull(301)],
  ]);
  expect(rows(areas[1]?.querySelector("ul"))).toEqual([["Return steers a running turn", pull(202)]]);
  // The title links its pull request too, not only the trailing number.
  expect(areas[1]?.querySelector<HTMLAnchorElement>("a.cl-change-link")?.href).toBe(pull(202));
  expect(rows(areas[2]?.querySelector("ul"))).toEqual([["Enroll Computer Use after peer check", pull(302)]]);
  // The installed build's own change is not part of the update.
  expect(fold?.textContent).not.toContain("installed build");
  // Internal work: listed with its pull requests, folded, never mixed into the areas.
  const hood = fold?.querySelector<HTMLDetailsElement>("details.cl-hood");
  expect(hood?.open).toBe(false);
  expect(hood?.querySelector("summary")?.textContent).toBe("Under the hood2");
  expect(rows(hood?.querySelector("ul"))).toEqual([
    ["Shard the gallery capture", pull(203)],
    ["The focus-loss drag test calls pointerFocusLost", pull(303)],
  ]);
  expect(areas.some((a) => a.textContent?.includes("shard"))).toBe(false);
  expect(fold?.textContent).not.toContain("internal changes");
});

test("a release day never takes a commit subject as its title", async () => {
  // The pipeline makes a digest from summary lines (entries "summary-N") and heads it with the
  // first line, a commit subject; a reviewed document's headline stays the day's title.
  const { releaseTitle } = await import("../src/pages/changelog/model");
  const digest = (headline: string, id: string) => ({
    ...notes("3940000000005", []),
    whatsNew: {
      version: "1.0.0-nightly.3940000000005",
      channel: "nightly" as const,
      date: "2026-10-20",
      headline: { en: headline },
      entries: [{ id, category: "improved" as const, title: { en: headline }, summary: { en: "" } }],
    },
  });
  expect(releaseTitle([digest("Enroll Computer Use after peer check", "summary-0")], "en")).toBeUndefined();
  expect(releaseTitle([digest("Agents can use your apps", "computer-use")], "en")).toBe("Agents can use your apps");
});

test("the update waits for all its notes: its fold never opens on one build and closes on the next", async () => {
  const { MockChangelogProvider } = await import("../src/pages/changelog/mockProvider");
  const { ChangelogOps } = await import("../src/pages/changelog/types");
  const { mountChangelogPage } = await import("../src/pages/changelog/main");
  // The newest build has bare changes only; the one before it has a curated note, held back.
  const curated = {
    ...notes("3940000000002", [{ title: "cmux-next sidebar: a click never drags", pr: 301 }]),
    whatsNew: {
      version: "1.0.0-nightly.3940000000002",
      channel: "nightly" as const,
      date: "2026-10-20",
      headline: { en: "Agents can use your apps" },
      entries: [
        {
          id: "computer-use",
          category: "new" as const,
          title: { en: "Agents can use your apps" },
          summary: { en: "" },
        },
      ],
    },
  };
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  let open = 0;
  class Held extends MockChangelogProvider {
    override async call<R>(op: string, params: unknown): Promise<R> {
      open += 1;
      try {
        if (op === ChangelogOps.get && (params as { build?: string }).build === curated.build) await held;
        return await super.call<R>(op, params);
      } finally {
        open -= 1;
      }
    }
  }
  const root = dom.window.document.createElement("div");
  dom.window.document.body.append(root);
  await act(async () => {
    mountChangelogPage(root, new Held([span[0]!, curated, span[2]!], "3940000000003") as never);
  });
  const settle = async (done: () => boolean) => {
    const deadline = performance.now() + 2_000;
    do {
      if (performance.now() > deadline) throw new Error("timed out waiting for the update's notes");
      await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    } while (!done());
  };
  const section = () => root.querySelector('[data-testid="changelog.sinceLastUpdate"]');
  // Every call but the held one is answered: the newest build's bare changes are in, yet nothing is drawn.
  await settle(() => open === 1 && !!section());
  expect(section()?.querySelector(".clj-placeholder")).not.toBeNull();
  expect(section()?.querySelector("details.cl-changes")).toBeNull();
  release();
  await settle(() => open === 0 && !section()?.querySelector(".clj-placeholder"));
  // With a curated note, the changes stay folded under it.
  expect(section()?.querySelector<HTMLDetailsElement>("details.cl-changes")?.open).toBe(false);
  expect(section()?.querySelector(".cln-lead-title")?.textContent).toBe("Agents can use your apps");
});
