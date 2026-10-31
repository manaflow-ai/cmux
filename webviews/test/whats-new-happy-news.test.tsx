// l10n-allow-file: test fixtures.
// "What's new since your last update" reads like happy news (Leo 2026-10-21): the top two or
// three changes lead with their pictures or clips, the rest of New and Improved are cards in a
// grid, and Fixed folds into one line ("Fixed 23 ›") instead of a long list. Since 2026-10-24
// ("it's like you're not even showing anything properly off") every change with a clip shows it
// whole, with its caption, and the row of three is the "lead" layout.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import type { ReleaseItem, ReleaseView } from "../src/pages/changelog/model";
import { clipItems, leadItems, SpanNews } from "../src/pages/changelog/SpanNews";
import type { NewsLayout } from "../src/pages/changelog/types";

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

const picture = {
  light: "data:image/webp;base64,UklGRg==",
  dark: "data:image/webp;base64,UklGRg==",
  alt: "",
  video: false,
};
const screenshot = {
  light: "data:image/png;base64,iVBORw==",
  dark: "data:image/png;base64,iVBORw==",
  alt: "",
  video: false,
};
const clip = { light: "media/b.mp4", dark: "media/b.mp4", alt: "", video: true };

function item(id: string, category: ReleaseItem["category"], extra: Partial<ReleaseItem> = {}): ReleaseItem {
  return { id, category, title: `Title ${id}`, summary: `Summary ${id}.\n\nMore about ${id}.`, ...extra };
}

function view(hero: ReleaseItem | undefined, groups: ReleaseView["groups"]): ReleaseView {
  const count = groups.reduce((n, g) => n + g.items.length, hero ? 1 : 0);
  return { hero, groups, changes: [], internalChanges: 0, underTheHood: [], count };
}

function render(v: ReleaseView, news?: NewsLayout): Document {
  const html = renderToStaticMarkup(<SpanNews view={v} ctx={{ strings, onTry: () => undefined, news }} />);
  return new JSDOM(`<!doctype html><body>${html}</body>`).window.document;
}

const fixes = Array.from({ length: 23 }, (_, i) => item(`fix${i}`, "fixed"));

test("PR-backed clips and leads show one PR chip per item alongside their existing actions", () => {
  const linked = item("linked", "new", {
    pr: "https://github.com/manaflow-ai/cmux/pull/27919",
    media: clip,
    action: { id: "palette.checkForUpdates" },
    docs: "https://cmux.com/docs/updates",
  });
  for (const layout of ["alternate", "stack", "grid", "lead"] as const) {
    const doc = render(view(linked, []), layout);
    const row = doc.querySelector(layout === "lead" ? ".cln-lead" : ".cln-clip")!;
    expect(row).not.toBeNull();
    expect(row.querySelector("h2")?.textContent).toContain(linked.title);
    expect(row.querySelectorAll("a.cl-pr").length).toBe(1);
    expect(row.querySelectorAll("a.cl-change-link").length).toBe(1);
    expect(row.querySelector<HTMLAnchorElement>(".cl-pr")?.href).toBe(linked.pr!);
    expect(row.querySelector(".cl-actions button")?.textContent).toBe("Try it");
    expect(row.querySelector<HTMLAnchorElement>(".cl-actions .cl-link")?.href).toBe(linked.docs!);
  }
});

test("every change with a clip shows it with its caption; the rest of New and Improved are cards", () => {
  const captioned = { ...picture, alt: "Archive a workspace from its menu." };
  const v = view(item("hero", "new", { media: captioned }), [
    { category: "new", items: [item("n1", "new"), item("n2", "new", { media: clip })] },
    {
      category: "improved",
      items: [item("i1", "improved", { media: picture }), item("i2", "improved", { media: picture })],
    },
    { category: "fixed", items: fixes },
  ]);
  expect(clipItems(v).map((i) => i.id)).toEqual(["hero", "n2", "i1", "i2"]);
  for (const layout of ["alternate", "stack", "grid", undefined] as const) {
    const doc = render(v, layout);
    expect(doc.querySelector(".cln-clips")?.className).toBe(`cln-clips cln-clips-${layout ?? "grid"}`);
    const clips = [...doc.querySelectorAll(".cln-clip")];
    expect(clips.map((c) => c.querySelector(".cln-clip-title")?.textContent)).toEqual([
      "Title hero",
      "Title n2",
      "Title i1",
      "Title i2",
    ]);
    // The caption says what you can now do: the clip's alt, else the change's first paragraph.
    expect(clips[0]!.querySelector(".cln-clip-caption")?.textContent).toBe("Archive a workspace from its menu.");
    expect(clips[2]!.querySelector(".cln-clip-caption")?.textContent).toBe("Summary i1.");
    expect(clips[1]!.querySelector("video")).not.toBeNull();
    expect(doc.querySelector(".cln-lead")).toBeNull();
    expect([...doc.querySelectorAll(".cln-card-title")].map((c) => c.textContent)).toEqual(["Title n1"]);
  }
});

test("a fix with a clip shows it beside the others and leaves the Fixed line", () => {
  const v = view(undefined, [
    { category: "new", items: [item("n1", "new", { media: picture })] },
    { category: "fixed", items: [item("f1", "fixed", { media: clip }), ...fixes] },
  ]);
  expect(clipItems(v).map((i) => i.id)).toEqual(["n1", "f1"]);
  const doc = render(v);
  expect([...doc.querySelectorAll(".cln-clip .cln-card-kind")].map((k) => k.textContent)).toEqual(["New", "Fixed"]);
  expect(doc.querySelector("details.cln-fixed summary")?.textContent).toBe("Fixed23");
});

test("beside clips, a hero without one leads in words", () => {
  const doc = render(view(item("hero", "new"), [{ category: "new", items: [item("n1", "new", { media: picture })] }]));
  expect([...doc.querySelectorAll(".cln-lead-title")].map((l) => l.textContent)).toEqual(["Title hero"]);
  expect(doc.querySelectorAll(".cln-clip").length).toBe(1);
});

test("a pull request's screenshot is not a clip: it leads as before", () => {
  const hero = item("hero", "new", { media: screenshot });
  const v = view(hero, [{ category: "new", items: [item("n1", "new"), item("n2", "new", { media: picture })] }]);
  expect(clipItems(v).map((i) => i.id)).toEqual(["n2"]);
  const doc = render(v);
  expect([...doc.querySelectorAll(".cln-clip .cln-clip-title")].map((t) => t.textContent)).toEqual(["Title n2"]);
  expect(doc.body.textContent).toContain("Title hero");
  expect(doc.querySelector(`.cln-clip img[src="${screenshot.light}"]`)).toBeNull();
  expect(doc.querySelector(`img[src="${screenshot.light}"]`)).not.toBeNull(); // the hero keeps its picture
});

test("the lead layout: the changes with pictures lead, up to three; the rest are cards; Fixed is one line", () => {
  const hero = item("hero", "new", { media: picture });
  const doc = render(
    view(hero, [
      { category: "new", items: [item("n1", "new"), item("n2", "new", { media: clip }), item("n3", "new")] },
      { category: "improved", items: [item("i1", "improved", { media: picture }), item("i2", "improved")] },
      { category: "fixed", items: fixes },
    ]),
    "lead",
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

test("the route names the news layout; grid by default", async () => {
  const { parseNewsLayout } = await import("../src/pages/changelog/store");
  expect(parseNewsLayout("")).toBe("grid");
  expect(parseNewsLayout("#/?from=1&to=2&news=alternate")).toBe("alternate");
  expect(parseNewsLayout("#/?news=stack")).toBe("stack");
  expect(parseNewsLayout("#/?news=lead")).toBe("lead");
  expect(parseNewsLayout("#/?news=bogus")).toBe("grid");
});
