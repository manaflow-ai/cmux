// Settings > Chief > Chiefs (u2586): every Chief with its picture, name, role, backend and lock;
// a row opens the same editor as Home (a page in the card, never a dialog), New Chief opens it
// empty, and Save goes through the host's page relay (`cmux.chief.profile.*`).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, changeValue, ops } = await import("./testing");

const card = (container: ParentNode) => container.querySelector<HTMLElement>('[data-card="chiefs"]')!;
const button = (scope: ParentNode, label: string) =>
  [...scope.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label)!;

test("Chiefs lists every Chief: picture, name, role, backend and lock", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  expect(rows.map((row) => row.dataset.chief)).toEqual(["agent_chief", "agent_release"]);
  expect(rows[0]!.textContent).toContain("Chief");
  expect(rows[0]!.textContent).toContain("Runs the team's agents");
  expect(rows[0]!.textContent).toContain("Default (Chief's usual)");
  expect(rows[0]!.querySelector(".chiefs-picture")).not.toBeNull();
  // One glass card, as every card on the page.
  expect(card(page.container).classList.contains("ui-glass")).toBe(true);
  // Named as people say them (the harness's model catalog, the composer's effort names), never by id.
  expect(rows[1]!.querySelector(".chiefs-backend")!.textContent).toBe("Codex · GPT-6 Astra · High");
  expect(rows[1]!.textContent).toContain("Locked");
  expect(rows[0]!.textContent).not.toContain("Locked");
  page.unmount();
});

test("a row names the backend the way Home and the Chief editor do, never by its raw id", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => {
      provider.chiefs[0]!.engine = { harness: "default", model: "opus" };
      provider.chiefs[1]!.engine = { harness: "unii" };
    },
  });
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  const backend = (row: HTMLElement) => row.querySelector(".chiefs-backend")!.textContent;
  // "default" is the default engine (Claude), as Home's chip reads it.
  expect(backend(rows[0]!)).toBe("Claude · opus");
  expect(backend(rows[1]!)).toBe("UniiChat");
  page.unmount();
});

test("a model the catalog does not name reads off its id, and an effort by its level name", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => {
      provider.chiefs[0]!.engine = { harness: "claude", model: "claude-opus-5-5", effort: "xhigh" };
      provider.chiefs[1]!.engine = { harness: "codex", model: "gpt-9-unlisted", effort: "medium" };
    },
  });
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  const backend = (row: HTMLElement) => row.querySelector(".chiefs-backend")!.textContent;
  expect(backend(rows[0]!)).toBe("Claude · Opus 5.5 · Extra High");
  // No name anywhere: the id itself, rather than a guess.
  expect(backend(rows[1]!)).toBe("Codex · gpt-9-unlisted · Medium");
  page.unmount();
});

test("the editor's pickers name models and efforts, and keep their ids as values", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await act(async () => card(page.container).querySelector<HTMLElement>('[data-chief="agent_release"]')!.click());
  await settle();
  const editor = card(page.container).querySelector<HTMLElement>("section.chief-editor")!;
  const model = editor.querySelector<HTMLSelectElement>('select[aria-label="Model"]')!;
  expect(model.value).toBe("gpt-6-astra");
  expect(model.selectedOptions[0]!.textContent).toBe("GPT-6 Astra");
  const effort = editor.querySelector<HTMLSelectElement>('select[aria-label="Effort"]')!;
  expect(effort.value).toBe("high");
  expect([...effort.options].map((option) => option.textContent)).toEqual(["Default", "Low", "Medium", "High"]);
  page.unmount();
});

test("a row shows a chosen model even when no harness is named", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    setup: (provider) => {
      provider.chiefs[0]!.engine = { model: "opus" };
      provider.chiefs[1]!.engine = { harness: "default" };
    },
  });
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  const backend = (row: HTMLElement) => row.querySelector(".chiefs-backend")!.textContent;
  expect(backend(rows[0]!)).toBe("Claude · opus");
  // The default engine with nothing else chosen reads the same as no engine at all.
  expect(backend(rows[1]!)).toBe("Default (Chief's usual)");
  page.unmount();
});

test("a row opens the same editor as Home, and Save goes through the host's relay", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await act(async () => card(page.container).querySelector<HTMLElement>('[data-chief="agent_release"]')!.click());
  await settle();
  const editor = card(page.container).querySelector<HTMLElement>("section.chief-editor");
  expect(editor).not.toBeNull();
  expect(page.container.querySelector('[role="dialog"]')).toBeNull();
  const name = editor!.querySelector<HTMLInputElement>('[aria-label="Name"]')!;
  expect(name.value).toBe("Release Chief");
  expect(editor!.querySelector<HTMLSelectElement>('[aria-label="Backend"]')!.value).toBe("codex");
  expect(editor!.querySelector<HTMLInputElement>("input[data-chief-lock]")!.checked).toBe(true);
  expect(editor!.querySelector("[data-chief-history]")).not.toBeNull();
  await changeValue(name, "Ship Chief");
  await act(async () => {
    editor!.querySelector("form")!.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  });
  await settle();
  expect(ops(page.provider, "cmux.chief.profile.update").at(-1)).toMatchObject({
    chief: "agent_release",
    display_name: "Ship Chief",
  });
  // Saved: the list again, with the new name.
  expect(card(page.container).querySelector("section.chief-editor")).toBeNull();
  expect(card(page.container).querySelector('[data-chief="agent_release"]')!.textContent).toContain("Ship Chief");
  page.unmount();
});

test("New Chief opens the editor empty; Back returns to the list", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  await act(async () => button(card(page.container), "New Chief").click());
  await settle();
  const editor = card(page.container).querySelector<HTMLElement>('section.chief-editor[data-chief-page="new"]')!;
  expect(editor.querySelector<HTMLInputElement>('[aria-label="Name"]')!.value).toBe("");
  await act(async () => editor.querySelector<HTMLButtonElement>('[aria-label="Back"]')!.click());
  await settle();
  expect(card(page.container).querySelectorAll("[data-chief]")).toHaveLength(2);
  page.unmount();
});

/** The picture a row draws: the img's src, whether it is a pixel-art mascot (drawn crisp, uncropped), and the letter disc's text if it draws one instead. */
const picture = (row: HTMLElement) => ({
  src: row.querySelector<HTMLImageElement>(".chiefs-picture img")?.getAttribute("src") ?? null,
  mascot: row.querySelector(".chiefs-picture img")?.hasAttribute("data-mascot") ?? false,
  initial: row.querySelector(".chiefs-initial")?.textContent ?? null,
});
const art = async (id: string) =>
  (await import("./components/ChiefPetCard")).CHIEF_PET_MASCOTS.find((entry) => entry.id === id)!.art;

test("a Chief with no picture of its own wears the chosen pet character, never a letter", async () => {
  // The default character (orb), with the pet itself off.
  let page = await renderPage({ path: "/settings/chief" });
  await settle();
  let rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  const orb = { src: await art("orb"), mascot: true, initial: null };
  expect(rows.map(picture)).toEqual([orb, orb]);
  page.unmount();
  // A chosen character, still with the pet off.
  page = await renderPage({ path: "/settings/chief", mock: { values: { "home.chiefPetMascot": "fox" } } });
  await settle();
  rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  const fox = { src: await art("fox"), mascot: true, initial: null };
  expect(rows.map(picture)).toEqual([fox, fox]);
  page.unmount();
});

test("a Chief with its own picture keeps it; the others wear the character", async () => {
  const page = await renderPage({
    path: "/settings/chief",
    mock: { values: { "home.chiefPetMascot": "moon" } },
    setup: (provider) => {
      provider.chiefs[1]!.avatar = { sha256: "sha-release", media_type: "image/png" };
      provider.chiefAvatars.set("agent_release", { media_type: "image/png", data: "UkVM" });
    },
  });
  await settle();
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  expect(rows.map(picture)).toEqual([
    { src: await art("moon"), mascot: true, initial: null },
    { src: "data:image/png;base64,UkVM", mascot: false, initial: null },
  ]);
  page.unmount();
});

// The Engine row (Leo's list 89(3); #64 decided the default): which Chief Home opens. Auto is this
// Mac's optchat-chief while it runs, else the Hosted Chief; This Mac and Hosted force one. It leads
// the Chiefs card for everyone, and each Chief's own harness stays in its editor.
const engine = (scope: ParentNode) => scope.querySelector<HTMLElement>('[data-row-key="home.chiefEngine"]');
const segments = (row: HTMLElement) =>
  [...row.querySelectorAll<HTMLInputElement>('input[type="radio"]')].map((input) => ({
    value: input.value,
    title: input.getAttribute("aria-label"),
    checked: input.checked,
  }));

test("the Chiefs card leads with an Engine row: Auto, This Mac or Hosted, Auto by default", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  const row = engine(card(page.container));
  expect(row).not.toBeNull();
  expect(row!.textContent).toContain("Engine");
  expect(segments(row!)).toEqual([
    { value: "auto", title: "Auto", checked: true },
    { value: "local", title: "This Mac", checked: false },
    { value: "hosted", title: "Hosted", checked: false },
  ]);
  // Above the list of Chiefs, and drawn once: the page's group list leaves it out.
  const list = card(page.container).querySelector("[data-chiefs]")!;
  expect(row!.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(page.container.querySelectorAll('[data-row-key="home.chiefEngine"]')).toHaveLength(1);
  page.unmount();
});

test("picking Hosted writes home.chiefEngine", async () => {
  const page = await renderPage({ path: "/settings/chief" });
  const hosted = engine(card(page.container))!.querySelector<HTMLInputElement>('input[value="hosted"]')!;
  await act(async () => hosted.click());
  await settle();
  expect(ops(page.provider, "cmux.settings.set")).toEqual([{ key: "home.chiefEngine", value: "hosted" }]);
  page.unmount();
});

test("a search result for the Engine row lands on it", async () => {
  const page = await renderPage({ path: "/settings/chief?focus=home.chiefEngine" });
  await settle();
  const row = engine(card(page.container))!;
  expect(row.contains(document.activeElement)).toBe(true);
  page.unmount();
});
