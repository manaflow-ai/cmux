// l10n-allow-file: test fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { IndexEntry } from "../src/pages/changelog/types";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";

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

// The Updated card lists the update's top changes right on it (u2441, gallery #01 "Compact list",
// 2026-10-19): the user wants to see what's new on the card, not one headline and a button. Every
// listed title shows; the count is only the changes not listed.
const data: UpdateHighlights = {
  version: "1.0.0-nightly.3934171000001",
  build: "3934171000001",
  fromVersion: "1.0.0-nightly.3913596493801",
  fromBuild: "3913596493801",
  date: "2026-10-19",
  source: "whatsNew" as const,
  language: "en",
  items: [
    {
      id: "dictation",
      title: "Dictation progress is announced to VoiceOver",
      summary: "Hears recording.",
      category: "fixed" as const,
    },
    { id: "new-tab", title: "New Tab names its project and machine at once", summary: null, category: "new" as const },
    { id: "smooth", title: "Chats stay smooth while an agent streams", summary: null, category: "improved" as const },
  ],
  moreCount: 35,
  changelog: { from: "1.0.0-nightly.3913596493801", to: "1.0.0-nightly.3934171000001" },
};

async function renderCard(d: UpdateHighlights, builds?: IndexEntry[]) {
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
        data={d}
        builds={builds}
        strings={createStrings(table)}
        actions={{ openChangelog: noop, dismiss: noop }}
      />,
    ),
  );
}

test("the Updated card lists the changes by area, then the count of the rest", async () => {
  await renderCard(data);
  // 2026-10-20, Lawrence on "Updated to nightly 3939068 / What's new in this build": "not descriptive
  // enough at all". The card names what changed, one line per area (updated-card-summary.test.tsx).
  expect(host.querySelector(".wn-card-headline")).toBeNull();
  const rows = [...host.querySelectorAll(".wn-card-areas li")].map((li) => li.textContent);
  expect(rows).toEqual([
    "Composer: dictation progress is announced to VoiceOver",
    "New Tab: New Tab names its project and machine at once",
    "Agent Chat: chats stay smooth while an agent streams",
  ]);
  expect(host.querySelector(".wn-card-more")?.textContent).toBe("+35 more");
  const buttons = [...host.querySelectorAll("button")].map((b) => b.textContent || b.getAttribute("aria-label"));
  expect(buttons).toEqual(["Close", "See What's New"]);
});

test("the Updated card says the version and date in words, not a raw build number", async () => {
  await renderCard(data);
  const eyebrow = host.querySelector(".wn-card-eyebrow")?.textContent ?? "";
  expect(eyebrow).toBe("Updated to Nightly · Oct 19");
  expect(eyebrow).not.toContain("3934171");
  // Without the commit, the build line names the build number, as the Update Ready card does.
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build 3934171");
  // The full build stays one hover away, for bug reports.
  expect(host.querySelector(".wn-card-eyebrow")?.getAttribute("title")).toBe(data.version);
});

test("a release version reads as itself, with its date", async () => {
  await renderCard({ ...data, version: "1.2.0" });
  expect(host.querySelector(".wn-card-eyebrow")?.textContent).toBe("Updated to 1.2.0 · Oct 19");
});

test("the Updated card with every change listed shows no count", async () => {
  await renderCard({ ...data, moreCount: 0 });
  expect(host.querySelectorAll(".wn-card-areas li").length).toBe(3);
  expect(host.querySelector(".wn-card-more")).toBeNull();
});

// Leo on nightly 4037004604601 (2026-10-26): "Like with this new update, I don't know what update this
// is, but, like, it just says updated to nightly, but that doesn't mean anything." The card says when
// the build was made, in the person's time zone, which commit it is and how far from the newest.
const leo: UpdateHighlights = {
  ...data,
  version: "1.0.0-nightly.4037004604601",
  build: "4037004604601",
  date: "2026-10-26",
  builtAt: "2026-10-26T12:00:00Z",
  head: "a9d1434de781a18ebae84d93d2b5a803864f5839",
};
const index = (builds: string[]): IndexEntry[] =>
  builds.map((build) => ({ build, shortVersion: `1.0.0-nightly.${build}`, date: "2026-10-26", highlights: 0 }));

test("the Updated card names the build by when it was made and its commit", async () => {
  await renderCard(leo);
  // The local time zone's day and time (the next test pins the zone and checks the words).
  const time = { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" } as const;
  const local = new Intl.DateTimeFormat("en-US", time).format(new Date(leo.builtAt!)).replace(/\s/g, " ");
  const eyebrow = host.querySelector(".wn-card-eyebrow")?.textContent?.replace(/\s/g, " ");
  expect(eyebrow).toBe(`Updated to Nightly · ${local}`);
  expect(host.querySelector(".wn-card-eyebrow")?.getAttribute("title")).toBe("1.0.0-nightly.4037004604601");
  // Until the notes index loads, the card knows the commit but not the newest build.
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434");
});

test("the build line says how far the build is from the newest", async () => {
  await renderCard(leo, index(["4037632091801", "4037226096601", "4037004604601", "4035798236101"]));
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434 · 2 builds behind newest");
  await renderCard(leo, index(["4037226096601", "4037004604601"]));
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434 · 1 build behind newest");
  await renderCard(leo, index(["4037004604601", "4035798236101"]));
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434 · Newest");
  // A pulled build is offered to no Mac: it is not newer.
  await renderCard({ ...leo, pulled: ["4037632091801"] }, index(["4037632091801", "4037226096601", "4037004604601"]));
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434 · 1 build behind newest");
  // An index that no longer lists the build says nothing about its place.
  await renderCard(leo, index(["4037632091801"]));
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build a9d1434");
  // Notes published before `head` reached the card: the index names the commit.
  const listed = index(["4037004604601"]).map((b) => ({ ...b, head: "3ce8dfda55b779e557c56e39c984ed75cff24b77" }));
  await renderCard({ ...leo, head: null }, listed);
  expect(host.querySelector(".wn-card-build")?.textContent).toBe("Build 3ce8dfd · Newest");
});

test("the build time reads in the person's locale and time zone", async () => {
  const { cardLabel } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const strings = createStrings(table, ["en-US"]);
  const label = (zone: string) => cardLabel(leo.version, leo.date, strings, "2026-10-26T19:38:52Z", zone);
  expect(label("UTC").replace(/\s/g, " ")).toBe("Nightly · Oct 26, 7:38 PM");
  expect(label("Asia/Tokyo").replace(/\s/g, " ")).toBe("Nightly · Oct 27, 4:38 AM");
  // No time: the build's day, as before.
  expect(cardLabel(leo.version, leo.date, strings, null)).toBe("Nightly · Oct 26");
  expect(cardLabel("1.2.0", leo.date, strings, "2026-10-26T19:38:52Z", "UTC").replace(/\s/g, " ")).toBe(
    "1.2.0 · Oct 26, 7:38 PM",
  );
});
