// The Update Ready card's popup (Leo 2026-10-13, cx-5dvig) adds only what the card lacks. The card
// says Update Ready, the short version and the date; the popup says "What's new in" the short build
// (the full one in its tooltip), lists the highlights and has "See all changes" once. It used to repeat the card: "<version> is ready" and
// the date again.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the popup names the full build, lists the highlights and has See all changes once", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={{
          version: "1.0.0-nightly.3845050428001",
          build: "3845050428001",
          fromVersion: "1.0.0-nightly.3801702344901",
          fromBuild: "3801702344901",
          date: "2026-10-13",
          source: "whatsNew",
          language: "en",
          items: [{ id: "groups", title: "Workspace groups you can see at a glance", summary: null, category: "new" }],
          moreCount: 2,
          changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
        }}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
      />,
    ),
  );
  const text = host.textContent ?? "";
  // A short, quiet title (Leo 2026-10-19); the raw build stays in its tooltip.
  expect(host.querySelector(".wn-pop-title")?.textContent).toBe("What's new in nightly 3845050");
  expect(host.querySelector(".wn-pop-title")?.getAttribute("title")).toBe("1.0.0-nightly.3845050428001");
  expect(text).toContain("Workspace groups you can see at a glance");
  // The card has these; the popup does not say them again.
  expect(text).not.toContain("is ready");
  expect(text).not.toContain("Oct 13");
  expect(text.split("See all changes").length - 1).toBe(1);
});

// The "Updated to" card (Leo 2026-10-13; version and date in words since 2026-10-20): "Nightly · Oct 13",
// the terse fallback headline when no change is known, and no Share cmux text link (it is the palette's).
test("the Updated card names the short build, says What's new in this build and has no Share link", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  const noop = () => undefined;
  await act(async () =>
    root!.render(
      <UpdatedCard
        data={{
          version: "1.0.0-nightly.3845050428001",
          build: "3845050428001",
          fromVersion: "1.0.0-nightly.3801702344901",
          fromBuild: "3801702344901",
          date: "2026-10-13",
          source: "none",
          language: "en",
          items: [],
          moreCount: 0,
          changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
        }}
        strings={createStrings(table)}
        actions={{ openChangelog: noop, dismiss: noop, share: noop } as never}
      />,
    ),
  );
  expect(host.querySelector(".wn-card-eyebrow")?.textContent).toBe("Updated to Nightly · Oct 13");
  expect(host.querySelector(".wn-card-headline")?.textContent).toBe("What's new in this build");
  const buttons = [...host.querySelectorAll("button")].map((b) => b.textContent || b.getAttribute("aria-label"));
  expect(buttons).toEqual(["Close", "See What's New"]);
});

// Notes published before the pipeline's readable rules (#21873) reach the card and popup as they
// were written: a digest title cut with "…", a work-stream line, and each title repeated as its
// description (nightly 3917159104301 and earlier). The surfaces read them as the page does.
test("the popup and the card read notes published before the readable rules as the page does", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights, UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const data = {
    version: "1.0.0-nightly.3917159104301",
    build: "3917159104301",
    fromVersion: "1.0.0-nightly.3917061587901",
    fromBuild: "3917061587901",
    date: "2026-10-19",
    source: "whatsNew" as const,
    language: "en",
    items: [
      {
        id: "summary-2",
        title: "Cmux NEXT perf-fanout: a restored New Tab page reads no tab…",
        summary: "Cmux NEXT perf-fanout: a restored New Tab page reads no tab list in its pane's snapshot",
        category: "improved" as const,
      },
      {
        id: "summary-1",
        title: "Export-backdrop-art reads each entry's subject box and…",
        summary: "Export-backdrop-art reads each entry's subject box and exports it",
        category: "improved" as const,
      },
      {
        id: "summary-0",
        title: "Keep the Mac awake while agents work",
        summary: "Keep the Mac awake while agents work",
        category: "fixed" as const,
      },
    ],
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.3917061587901", to: "1.0.0-nightly.3917159104301" },
  };
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights data={data} strings={createStrings(table)} actions={{ openChangelog: () => undefined }} />,
    ),
  );
  const items = [...host.querySelectorAll(".wn-pop-list li")].map((li) => li.textContent);
  // The perf-fanout line and the export-backdrop-art tool line are internal work.
  expect(items).toEqual(["1Keep the Mac awake while agents work"]);
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdatedCard data={data} strings={createStrings(table)} actions={{ openChangelog: () => undefined }} />,
    ),
  );
  // The card summarizes by area (#22810): one row, made only of the readable change.
  const rows = [...host.querySelectorAll(".wn-card-areas li")].map((li) => li.textContent ?? "");
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatch(/keep the mac awake while agents work/i);
  expect(rows[0]).not.toMatch(/perf-fanout|backdrop/i);
  expect(host.querySelector(".wn-card-line")).toBeNull();
});

// Review of #22099: the popover's scrolling list (`rest`, every change after the first three) and the
// card's summary read through the same rules as the first three. An internal line, a title cut with
// "…" and a repeat of a change already shown never reach either surface.
test("every change after the first three reads as the first three do, on the popup and the card", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights, UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const data = {
    version: "1.0.0-nightly.3917159104301",
    build: "3917159104301",
    fromVersion: "1.0.0-nightly.3917061587901",
    fromBuild: "3917061587901",
    date: "2026-10-19",
    source: "summary" as const,
    language: "en",
    items: [
      {
        id: "summary-0",
        title: "Keep the Mac awake while agents work",
        summary: null,
        category: "fixed" as const,
      },
    ],
    rest: [
      {
        id: "summary-3",
        title: "Cmux NEXT perf-fanout: a restored New Tab page reads no tab…",
        summary: "Cmux NEXT perf-fanout: a restored New Tab page reads no tab list in its pane's snapshot",
        category: "improved" as const,
      },
      {
        id: "summary-4",
        title: "Terminals show background art through the glass, like the…",
        summary: "Terminals show background art through the glass, like the other panes",
        category: "improved" as const,
      },
      {
        id: "summary-5",
        title: "Keep the Mac awake while agents work",
        summary: null,
        category: "fixed" as const,
      },
    ],
    moreCount: 3,
    changelog: { from: "1.0.0-nightly.3917061587901", to: "1.0.0-nightly.3917159104301" },
  };
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights data={data} strings={createStrings(table)} actions={{ openChangelog: () => undefined }} />,
    ),
  );
  const rest = [...host.querySelectorAll(".wn-pop-rest li")].map((li) => li.textContent ?? "");
  expect(rest).toHaveLength(1);
  expect(rest[0]).toMatch(/^Terminals show background art through the glass/);
  expect(rest[0]).not.toContain("…");
  const text = host.textContent ?? "";
  expect(text).not.toMatch(/perf-fanout/i);
  expect(text.split("Keep the Mac awake while agents work").length - 1).toBe(1);
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdatedCard data={data} strings={createStrings(table)} actions={{ openChangelog: () => undefined }} />,
    ),
  );
  const card = host.textContent ?? "";
  expect(card).not.toMatch(/perf-fanout/i);
  expect(card).not.toContain("…");
});

// Notes with screenshots (Leo 2026-10-19): a change's picture shows inline at the popover's width,
// in the theme's scheme, and a click on it opens the notes, where it shows larger.
test("a change's picture shows inline and a click on it opens the notes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  let opened = 0;
  const light = "data:image/png;base64,iVBORw0KGgo=";
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={{
          version: "1.0.0-nightly.3932981759301",
          build: "3932981759301",
          fromVersion: "1.0.0-nightly.3917159104301",
          fromBuild: "3917159104301",
          date: "2026-10-19",
          source: "whatsNew",
          language: "en",
          items: [
            {
              id: "groups",
              title: "Workspace groups you can see at a glance",
              summary: "Colored labels, icons, and pins that keep a group.",
              category: "new",
              media: { light, dark: "data:image/png;base64,AAAA", alt: "The sidebar with workspace groups" },
            },
            {
              id: "undo",
              title: "Undo a tab close from a toast",
              summary: null,
              category: "new",
              // A remote file the host never inlined: it must not load in the popup.
              media: { light: "https://cmux.com/a.png", dark: "media/1.0/a.png", alt: "x" },
            },
          ],
          moreCount: 0,
          changelog: { from: "1.0.0-nightly.3917159104301", to: "1.0.0-nightly.3932981759301" },
        }}
        strings={createStrings(table)}
        actions={{ openChangelog: () => void opened++ }}
      />,
    ),
  );
  expect(host.querySelector(".wn-pop-title")?.textContent).toBe("What's new in nightly 3932981");
  const pictures = [...host.querySelectorAll(".wn-pop-list li")].map((li) => li.querySelectorAll("img").length);
  expect(pictures).toEqual([1, 0]);
  expect(host.querySelectorAll(".wn-pop-media").length).toBe(1);
  const button = host.querySelector<HTMLButtonElement>(".wn-pop-media")!;
  expect(button.getAttribute("aria-label")).toBe("The sidebar with workspace groups");
  expect(button.querySelector("img")?.getAttribute("src")).toBe(light);
  await act(async () => button.click());
  expect(opened).toBe(1);
});

// Lawrence 2026-10-19 (msg 2371): hovering the Update Ready card must show at once what is going to
// change: the version this Mac runs now beside the staged one, the changes, and a way to the notes.
// A staged update without a change list still says what changes (the versions) and links its
// release notes, never an empty card.
const readyData = (items: { id: string; title: string; summary: string | null; category: "new" }[]) => ({
  version: "1.0.0-nightly.3845050428001",
  build: "3845050428001",
  fromVersion: "1.0.0-nightly.3801702344901",
  fromBuild: "3801702344901",
  date: "2026-10-13",
  source: (items.length ? "whatsNew" : "none") as "whatsNew" | "none",
  language: "en",
  items,
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
});

test("the update card's hover card says which version it updates from", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={readyData([{ id: "groups", title: "Workspace groups", summary: null, category: "new" }])}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
      />,
    ),
  );
  expect(host.querySelector(".wn-pop-from")?.textContent).toBe("Updating from nightly 3801702");
  expect(host.textContent).toContain("Workspace groups");
  expect(host.textContent).toContain("See all changes");
});

test("without a change list the hover card shows the versions and See release notes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  let opened = 0;
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={readyData([])}
        strings={createStrings(table)}
        actions={{ openChangelog: () => void opened++ }}
      />,
    ),
  );
  expect(host.querySelector(".wn-pop-from")?.textContent).toBe("Updating from nightly 3801702");
  expect(host.querySelector(".wn-pop-list")).toBeNull();
  const link = host.querySelector<HTMLButtonElement>(".wn-pop-all");
  expect(link?.textContent).toContain("See release notes");
  expect(host.textContent).not.toContain("See all changes");
  await act(async () => link!.click());
  expect(opened).toBe(1);
});

// Review of #22099: the footer counts what the popup shows. Only internal work: no list, so it
// offers the release notes, not "See all changes" of nothing.
test("an update whose every change is internal offers See release notes, not See all changes", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  act(() => root?.unmount());
  root = createRoot(host);
  const data = {
    ...readyData([]),
    source: "summary" as const,
    items: [
      {
        id: "summary-0",
        title: "Export-backdrop-art reads each entry's subject box and…",
        summary: "Export-backdrop-art reads each entry's subject box and exports it",
        category: "improved" as const,
      },
    ],
  };
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights data={data} strings={createStrings(table)} actions={{ openChangelog: () => undefined }} />,
    ),
  );
  expect(host.querySelector(".wn-pop-list")).toBeNull();
  expect(host.querySelector(".wn-pop-all")?.textContent).toContain("See release notes");
  expect(host.textContent).not.toContain("See all changes");
});
