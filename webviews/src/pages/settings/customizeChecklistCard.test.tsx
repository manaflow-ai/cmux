// Settings > Customize (`#/settings/customize`, Leo, 2026-11-22, ask-931361017e): one dense checklist,
// one click per customization. A switch writes the setting as its own row does, a managed key stays
// locked, a library entry runs `customize library on|off`, every other switch waits in a collapsed
// group, and one search opens every group to what matches.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, changeValue } = await import("./testing");
const { mockManagedKey } = await import("./mockProvider");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="customizeChecklist"]')!;
const group = (id: string) => card().querySelector<HTMLElement>(`[data-checklist-group="${id}"]`);
const item = (id: string) => card().querySelector<HTMLElement>(`[data-checklist-item="${id}"]`);
const toggle = (id: string) => item(id)!.querySelector<HTMLButtonElement>('[role="switch"]')!;
const ids = (id: string) =>
  [...(group(id)?.querySelectorAll<HTMLElement>("[data-checklist-item]") ?? [])].map(
    (row) => row.dataset.checklistItem,
  );
const count = (id: string) => group(id)!.querySelector("[data-checklist-count]")!.textContent;

async function open() {
  page = await renderPage({ path: "/settings/customize" });
  await settle();
  return page;
}

test("Settings > Customize lists the schema's experiments and Labs, each with a switch and a count", async () => {
  await open();
  expect(card()).not.toBeNull();
  expect(ids("labs")).toContain("labs.liveTree");
  expect(ids("labs")).toContain("customize.fromTheApp");
  expect(ids("experiments")!.every((id) => id!.startsWith("experiments."))).toBe(true);
  // Leo named Agent Badges first: the exported schema's experiments are all here.
  expect(ids("experiments")).toContain("experiments.agentBadges");
  expect(ids("experiments")).toContain("experiments.agentBadgesBeam");
  expect(count("labs")).toBe(`0 of ${ids("labs").length} on`);
});

test("one click turns a Labs switch on through settings.set, and the count follows", async () => {
  await open();
  expect(toggle("labs.liveTree").getAttribute("aria-checked")).toBe("false");
  await click(toggle("labs.liveTree"));
  await settle();
  expect(toggle("labs.liveTree").getAttribute("aria-checked")).toBe("true");
  expect(page!.store.getSnapshot().rows.get("labs.liveTree")?.value).toBe(true);
  expect(count("labs")).toBe(`1 of ${ids("labs").length} on`);
});

test("a sidebar look is one switch: on picks it, off puts back the default look (ask-b9d8846cc2)", async () => {
  await open();
  // Today's look (cmux) has no switch; the other looks wait off, so nothing changes until a click.
  expect(ids("looks")).not.toContain("sidebar.look=cmux");
  expect(ids("looks")).toContain("sidebar.look=claude");
  expect(toggle("sidebar.look=claude").getAttribute("aria-checked")).toBe("false");
  await click(toggle("sidebar.look=claude"));
  await settle();
  expect(page!.store.getSnapshot().rows.get("sidebar.look")?.value).toBe("claude");
  expect(toggle("sidebar.look=claude").getAttribute("aria-checked")).toBe("true");
  await click(toggle("sidebar.look=claude"));
  await settle();
  expect(page!.store.getSnapshot().rows.get("sidebar.look")?.value).toBe("cmux");
  expect(toggle("sidebar.look=claude").getAttribute("aria-checked")).toBe("false");
});

test("a library entry's switch runs `customize library off`", async () => {
  await open();
  expect(ids("library")).toContain("library:night");
  await click(toggle("library:night"));
  await settle();
  expect(page!.provider.libraryRuns).toEqual([{ verb: "off", name: "night" }]);
  expect(toggle("library:night").getAttribute("aria-checked")).toBe("false");
});

test("every other switch is collapsed under All Switches; opening it shows the managed key locked", async () => {
  await open();
  const opener = group("all")!.querySelector<HTMLButtonElement>(".checklist-toggle-all")!;
  expect(opener.getAttribute("aria-expanded")).toBe("false");
  expect(ids("all")).toEqual([]);
  await click(opener);
  expect(opener.getAttribute("aria-expanded")).toBe("true");
  expect(ids("all")!.length).toBeGreaterThan(20);
  expect(toggle(mockManagedKey).disabled).toBe(true);
  expect(item(mockManagedKey)!.dataset.locked).toBe("");
});

test("the search filters every group at once and opens All Switches to its matches", async () => {
  await open();
  const search = card().querySelector<HTMLInputElement>('input[type="search"]')!;
  await changeValue(search, mockManagedKey);
  expect(
    [...card().querySelectorAll<HTMLElement>("[data-checklist-group]")].map((each) => each.dataset.checklistGroup),
  ).toEqual(["all"]);
  expect(ids("all")).toEqual([mockManagedKey]);
  await changeValue(search, "no switch is called this");
  expect(card().querySelector("[data-checklist-group]")).toBeNull();
  expect(card().textContent).toContain("no switch is called this");
});
