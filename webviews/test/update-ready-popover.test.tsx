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

// The "Updated to" card (Leo 2026-10-13): the short build ("nightly 3845050", the long one
// truncated), the terse fallback headline, and no Share cmux text link (it is the palette's).
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
  expect(host.querySelector(".wn-card-eyebrow")?.textContent).toBe("Updated to nightly 3845050");
  expect(host.querySelector(".wn-card-headline")?.textContent).toBe("What's new in this build");
  const buttons = [...host.querySelectorAll("button")].map((b) => b.textContent || b.getAttribute("aria-label"));
  expect(buttons).toEqual(["Close", "See What's New"]);
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
