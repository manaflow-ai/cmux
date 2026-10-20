// Settings > Agents > Chiefs (u2586): every Chief with its picture, name, role, backend and lock;
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
  const page = await renderPage({ path: "/settings/agents" });
  const rows = [...card(page.container).querySelectorAll<HTMLElement>("[data-chief]")];
  expect(rows.map((row) => row.dataset.chief)).toEqual(["agent_chief", "agent_release"]);
  expect(rows[0]!.textContent).toContain("Chief");
  expect(rows[0]!.textContent).toContain("Runs the team's agents");
  expect(rows[0]!.textContent).toContain("Default (Chief's usual)");
  expect(rows[0]!.querySelector(".chiefs-picture")).not.toBeNull();
  expect(rows[1]!.textContent).toContain("Codex · gpt-6-astra · high");
  expect(rows[1]!.textContent).toContain("Locked");
  expect(rows[0]!.textContent).not.toContain("Locked");
  page.unmount();
});

test("a row names the backend the way Home and the Chief editor do, never by its raw id", async () => {
  const page = await renderPage({
    path: "/settings/agents",
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

test("a row shows a chosen model even when no harness is named", async () => {
  const page = await renderPage({
    path: "/settings/agents",
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
  const page = await renderPage({ path: "/settings/agents" });
  await act(async () => card(page.container).querySelector<HTMLElement>('[data-chief="agent_release"]')!.click());
  await settle();
  const editor = card(page.container).querySelector<HTMLElement>("section.chief-editor");
  expect(editor).not.toBeNull();
  expect(page.container.querySelector('[role="dialog"]')).toBeNull();
  const name = editor!.querySelector<HTMLInputElement>('[aria-label="Name"]')!;
  expect(name.value).toBe("Release Chief");
  expect(editor!.querySelector<HTMLSelectElement>('[aria-label="Backend"]')!.value).toBe("codex");
  expect(editor!.querySelector<HTMLInputElement>('input[data-chief-lock]')!.checked).toBe(true);
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
  const page = await renderPage({ path: "/settings/agents" });
  await act(async () => button(card(page.container), "New Chief").click());
  await settle();
  const editor = card(page.container).querySelector<HTMLElement>('section.chief-editor[data-chief-page="new"]')!;
  expect(editor.querySelector<HTMLInputElement>('[aria-label="Name"]')!.value).toBe("");
  await act(async () => editor.querySelector<HTMLButtonElement>('[aria-label="Back"]')!.click());
  await settle();
  expect(card(page.container).querySelectorAll("[data-chief]")).toHaveLength(2);
  page.unmount();
});
