// Settings > Appearance > Looks: the card reads the CLI's answers (a verb's JSON, the consent card an
// install without --yes answers, a refusal in the CLI's own words), says the consent card in the
// page's words, pins the commit the card showed, and sends `order` every installed id top first.
// On the page: Appearance leads with the gallery; Install shows the consent card and installs only
// after it, pinned; an installed look turns off, moves and uninstalls (after asking).
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockOptions } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { consentLines, moveOrder, pinnedReference, readLooksAnswer, asGallery, asPreview } =
  await import("./looksGallery");
const { mockConsentCard, mockStackedLooks } = await import("./mockLooks");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

test("order moves one id a step and keeps every other id in place, top first", () => {
  const ids = ["a", "b", "c"];
  expect(moveOrder(ids, "b", -1)).toEqual(["b", "a", "c"]);
  expect(moveOrder(ids, "b", 1)).toEqual(["a", "c", "b"]);
  expect(moveOrder(ids, "a", -1)).toBeNull();
  expect(moveOrder(ids, "c", 1)).toBeNull();
  expect(moveOrder(ids, "z", 1)).toBeNull();
  expect(ids).toEqual(["a", "b", "c"]);
});

test("an answer is the verb's JSON, the consent card, or the CLI's refusal", () => {
  const card = mockConsentCard("manaflow-ai/paper-look");
  expect(readLooksAnswer({ looks: [], stack: [] })).toEqual({ kind: "value", value: { looks: [], stack: [] } });
  expect(readLooksAnswer({ code: "setup.needs_consent", message: "nothing was changed", details: card })).toEqual({
    kind: "consent",
    card,
  });
  // Wrapped the way the CLI prints it on stdout, too.
  expect(readLooksAnswer({ error: { code: "setup.needs_consent", details: card } }).kind).toBe("consent");
  expect(readLooksAnswer({ code: "setup.refused", message: "offline", details: {} })).toEqual({
    kind: "refusal",
    code: "setup.refused",
    message: "offline",
  });
  // A consent envelope without a card (no commit) is a refusal: nothing to pin, nothing installs.
  const bare = readLooksAnswer({ code: "setup.needs_consent", message: "m", details: { setup: { id: "x" } } });
  expect(bare.kind).toBe("refusal");
  expect(asGallery({ looks: [] })).toBeNull();
  expect(asPreview({ dataUrl: "https://example.com/x.png" })).toBeNull();
});

test("Install pins the commit the card showed, whatever ref the reference named", () => {
  const card = mockConsentCard("manaflow-ai/paper-look");
  expect(pinnedReference(card)).toBe(`github.com/manaflow-ai/cmux-paper-look@${card.source.commit}`);
  const moved = { ...card, source: { ...card.source, reference: "github.com/manaflow-ai/cmux-paper-look@main" } };
  expect(pinnedReference(moved)).toBe(`github.com/manaflow-ai/cmux-paper-look@${card.source.commit}`);
});

test("the consent card lists theme, settings (with the person's value), files, actions, extensions and scopes", () => {
  const look = consentLines(mockConsentCard("manaflow-ai/studio-look"));
  expect(look.map((line) => line.kind)).toEqual(["theme", "setting", "setting", "file", "file", "action"]);
  expect(look[2]).toMatchObject({ replaces: true });
  expect(look[2]!.text).toContain("#8e8e93");
  const views = consentLines(mockConsentCard("manaflow-ai/newtab-cards-look"));
  const extension = views.find((line) => line.kind === "extension")!;
  expect(extension.text).toContain("github.com/manaflow-ai/cmux-newtab-feed");
  expect(extension.text).toContain("chats:read, projects:read");
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="looksGallery"]');
const tile = (id: string) => card()!.querySelector<HTMLElement>(`[data-look="${id}"]`)!;
const layer = (id: string) => card()!.querySelector<HTMLElement>(`[data-looks-layer="${id}"]`)!;
const looksCalls = () =>
  page!.provider.log.filter((call) => call.op === "cmux.settings.looks").map((call) => call.params as { verb: string });

async function open(mock?: MockOptions) {
  page = await renderPage({ path: "/settings/appearance", mock });
  await settle();
  return page;
}

test("Appearance leads with the gallery; Install shows the consent card, then installs pinned", async () => {
  await open();
  expect(card()).not.toBeNull();
  // Each tile asked for its own golden sample (no IntersectionObserver here: every tile is near).
  await settle();
  const previews = [...card()!.querySelectorAll<HTMLElement>("[data-looks-preview]")].map(
    (frame) => frame.dataset.looksPreview,
  );
  expect(previews).toEqual(["shown", "shown", "shown", "shown"]);
  const install = tile("manaflow-ai/paper-look").querySelector<HTMLButtonElement>('[data-looks-action="install"]')!;
  await click(install);
  await settle();
  const sheet = card()!.querySelector<HTMLElement>('[data-looks-consent="manaflow-ai/paper-look"]')!;
  expect(sheet).not.toBeNull();
  // Nothing installed yet: the stack is empty until the person confirms.
  expect(page!.provider.looks.stack).toEqual([]);
  const confirm = sheet.querySelector<HTMLButtonElement>('[data-looks-action="confirmInstall"]')!;
  // UI drivers find the confirm by its accessible name, as they find the tiles'.
  expect(confirm.getAttribute("aria-label")).toBe("Install");
  await click(confirm);
  await settle();
  const runs = page!.provider.looksRuns;
  expect(runs.at(-1)).toEqual({
    verb: "install",
    reference: pinnedReference(mockConsentCard("manaflow-ai/paper-look")),
    yes: true,
  });
  expect(card()!.querySelector("[data-looks-consent]")).toBeNull();
  expect(tile("manaflow-ai/paper-look").hasAttribute("data-installed")).toBe(true);
  expect(layer("manaflow-ai/paper-look")).not.toBeNull();
  // The gallery was read again after the install.
  expect(looksCalls().filter((call) => call.verb === "gallery").length).toBeGreaterThan(1);
});

test("a stacked look moves down with every id in the new order, and uninstall asks first", async () => {
  await open({ looks: mockStackedLooks() });
  await click(layer("manaflow-ai/paper-look").querySelector<HTMLButtonElement>('[data-looks-action="down"]')!);
  await settle();
  expect(page!.provider.looksRuns.at(-1)).toEqual({
    verb: "order",
    ids: ["manaflow-ai/studio-look", "manaflow-ai/paper-look", "someone/terminal-tweaks"],
  });
  await click(layer("manaflow-ai/studio-look").querySelector<HTMLButtonElement>('[data-looks-action="remove"]')!);
  await settle();
  expect(page!.provider.looksRuns.at(-1)?.verb).toBe("order");
  const confirm = card()!.querySelector<HTMLElement>('[data-looks-confirm="manaflow-ai/studio-look"]')!;
  await click(confirm.querySelector<HTMLButtonElement>('[data-looks-action="confirmRemove"]')!);
  await settle();
  expect(page!.provider.looksRuns.at(-1)).toEqual({ verb: "remove", id: "manaflow-ai/studio-look" });
  expect(card()!.querySelector('[data-looks-layer="manaflow-ai/studio-look"]')).toBeNull();
});

test("a refused change shows the CLI's words", async () => {
  await open({ looks: mockStackedLooks(), looksRefusal: "the stack is locked" });
  await click(layer("manaflow-ai/paper-look").querySelector<HTMLButtonElement>('[role="switch"]')!);
  await settle();
  expect(card()!.querySelector("[data-looks-refusal]")?.textContent).toContain("the stack is locked");
});

test("a host without the Looks part draws no card", async () => {
  await open({ failing: { "cmux.settings.looks": "cmux.protocol.unknown_op" } });
  expect(card()).toBeNull();
});

// Leo, 2026-11-27: "im not a fan of the descriptions on our themes and whatnot". Look Descriptions
// (`experiments.lookDescriptions`): one short phrase by default, the name alone, or the phrase and
// its traits as one tag line.
test("each look says one short phrase by default, only its name, or its phrase and tag line", async () => {
  const words = () => {
    const paper = tile("manaflow-ai/paper-look");
    return [
      paper.querySelector(".looks-tagline")?.textContent ?? null,
      paper.querySelector(".looks-traits")?.textContent ?? null,
    ];
  };
  await open();
  expect(words()).toEqual(["Warm, roomy, serif replies.", null]);
  page!.unmount();
  await open({ values: { "experiments.lookDescriptions": "name" } });
  expect(words()).toEqual([null, null]);
  page!.unmount();
  await open({ values: { "experiments.lookDescriptions": "tagged" } });
  expect(words()).toEqual(["Warm, roomy, serif replies.", "Light · Roomy"]);
});
