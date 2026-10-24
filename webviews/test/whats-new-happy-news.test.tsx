// l10n-allow-file: test fixtures.
// "What's new since your last update" reads like happy news (Leo 2026-10-21): the top two or
// three changes lead with their pictures or clips, the rest of New and Improved are cards in a
// grid, and Fixed folds into one line ("Fixed 23 ›") instead of a long list.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import type { ReleaseItem, ReleaseView } from "../src/pages/changelog/model";
import { leadItems, SpanNews } from "../src/pages/changelog/SpanNews";

const strings = {
  language: "en",
  t: (key: string) =>
    ({
      "changelog.group.new": "New",
      "changelog.group.improved": "Improved",
      "changelog.group.fixed": "Fixed",
      "changelog.group.security": "Security",
      "changelog.page.learnMore": "Learn more",
      "changelog.page.tryIt": "Try it",
    })[key] ?? key,
  format: (key: string, ...args: string[]) => `${key} ${args.join(" ")}`,
};

const picture = { light: "media/a.png", dark: "media/a.png", alt: "", video: false };
const clip = { light: "media/b.mp4", dark: "media/b.mp4", alt: "", video: true };

function item(id: string, category: ReleaseItem["category"], extra: Partial<ReleaseItem> = {}): ReleaseItem {
  return { id, category, title: `Title ${id}`, summary: `Summary ${id}.\n\nMore about ${id}.`, ...extra };
}

function view(hero: ReleaseItem | undefined, groups: ReleaseView["groups"]): ReleaseView {
  const count = groups.reduce((n, g) => n + g.items.length, hero ? 1 : 0);
  return { hero, groups, changes: [], internalChanges: 0, underTheHood: [], count };
}

function render(v: ReleaseView): Document {
  const html = renderToStaticMarkup(<SpanNews view={v} ctx={{ strings, onTry: () => undefined }} />);
  return new JSDOM(`<!doctype html><body>${html}</body>`).window.document;
}

const fixes = Array.from({ length: 23 }, (_, i) => item(`fix${i}`, "fixed"));

test("the changes with pictures lead, up to three; the rest of New and Improved are cards; Fixed is one line", () => {
  const hero = item("hero", "new", { media: picture });
  const doc = render(
    view(hero, [
      { category: "new", items: [item("n1", "new"), item("n2", "new", { media: clip }), item("n3", "new")] },
      { category: "improved", items: [item("i1", "improved", { media: picture }), item("i2", "improved")] },
      { category: "fixed", items: fixes },
    ]),
  );
  const leads = [...doc.querySelectorAll(".cln-lead")];
  expect(leads.map((l) => l.querySelector(".cln-lead-title")?.textContent)).toEqual([
    "Title hero",
    "Title n2",
    "Title i1",
  ]);
  // Each lead shows its picture or plays its clip in place, and its first paragraph.
  expect(leads[1]!.querySelector("video")).not.toBeNull();
  expect(leads[0]!.querySelector("img")).not.toBeNull();
  expect(leads[0]!.querySelector(".cln-lead-summary")?.textContent).toBe("Summary hero.");
  const cards = [...doc.querySelectorAll(".cln-cards .cln-card")];
  expect(cards.map((c) => c.querySelector(".cln-card-title")?.textContent)).toEqual([
    "Title n1",
    "Title n3",
    "Title i2",
  ]);
  expect(cards.map((c) => c.querySelector(".cln-card-kind")?.textContent)).toEqual(["New", "New", "Improved"]);
  // Fixed: one folded line with its count, never a list in the open.
  const fixed = doc.querySelector<HTMLDetailsElement>("details.cln-fixed");
  expect(fixed?.hasAttribute("open")).toBe(false);
  expect(fixed?.querySelector("summary")?.textContent).toBe("Fixed23");
  expect(fixed?.querySelectorAll("li").length).toBe(23);
  expect(doc.querySelector(".cl-group")).toBeNull();
});

test("with no pictures, two New changes lead and nothing else is a headline", () => {
  const v = view(undefined, [
    { category: "new", items: [item("n1", "new"), item("n2", "new"), item("n3", "new")] },
    { category: "improved", items: [item("i1", "improved")] },
  ]);
  expect(leadItems(v).map((i) => i.id)).toEqual(["n1", "n2"]);
  const doc = render(v);
  expect(doc.querySelectorAll(".cln-card").length).toBe(2);
  expect(doc.querySelector(".cln-fixed")).toBeNull();
});

test("Security keeps its own open list", () => {
  const doc = render(view(undefined, [{ category: "security", items: [item("s1", "security")] }]));
  expect(doc.querySelector(".cl-group h3")?.textContent).toBe("Security");
  expect(doc.querySelector(".cl-group .cl-row-title")?.textContent).toBe("Title s1");
});

test("when fixes are all the update's news, their list is open", () => {
  const doc = render(view(undefined, [{ category: "fixed", items: fixes }]));
  expect(doc.querySelector<HTMLDetailsElement>("details.cln-fixed")?.hasAttribute("open")).toBe(true);
  // Anything else to lead with keeps Fixed to its one line.
  const led = render(
    view(undefined, [
      { category: "new", items: [item("n1", "new")] },
      { category: "fixed", items: fixes },
    ]),
  );
  expect(led.querySelector<HTMLDetailsElement>("details.cln-fixed")?.hasAttribute("open")).toBe(false);
});

test("a fix keeps its Learn more link", () => {
  const fix = item("f1", "fixed", { docs: "https://cmux.com/docs/fix" });
  const doc = render(view(undefined, [{ category: "fixed", items: [fix] }]));
  expect(doc.querySelector<HTMLAnchorElement>(".cln-fixed .cl-row-link")?.href).toBe("https://cmux.com/docs/fix");
});
