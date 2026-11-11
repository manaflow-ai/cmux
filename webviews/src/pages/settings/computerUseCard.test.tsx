// Settings > Computer Use: one category holds every cmux Computer Use setting. The card says it is
// built in, shows the status (engine, permissions with Grant, worker) from the host lists'
// `computer_use`, live; the mode picker with a line per mode, the denied apps editor, the saved
// approvals and the switches. Every write goes through cmux.settings.set; every button runs a
// shared catalog action.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import type { ComputerUseState } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const PATH = "/settings/computer-use";
const card = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="computer-use"]');
const grants = (element: HTMLElement) =>
  [...element.querySelectorAll<HTMLElement>("[data-granted]")].map((badge) => badge.dataset.granted);
const ready: ComputerUseState = {
  phase: "ready",
  accessibility: true,
  screen_recording: false,
  helper: null,
  engine: "cmux Computer Use 1.0",
  worker: { state: "running", pid: 4242 },
};
type Entry = { op: string; params: unknown };
const wrote = (log: Entry[], key: string, value: unknown) =>
  log.some(
    (entry) =>
      entry.op === "cmux.settings.set" &&
      (entry.params as { key: string }).key === key &&
      JSON.stringify((entry.params as { value: unknown }).value) === JSON.stringify(value),
  );
const ran = (log: Entry[], action: string, args?: Record<string, unknown>) =>
  log.some(
    (entry) =>
      entry.op === "cmux.app.action.run" &&
      (entry.params as { action: string }).action === action &&
      (args === undefined || JSON.stringify((entry.params as { args: unknown }).args) === JSON.stringify(args)),
  );

test("Computer Use is its own category, and Agents no longer draws it", async () => {
  const agents = await renderPage({ path: "/settings/agents" });
  await settle();
  expect(card(agents.container)).toBeNull();
  expect(agents.container.querySelector('[data-row-key^="computerUse."]')).toBeNull();
  agents.unmount();
  const page = await renderPage({ path: PATH });
  await settle();
  const element = card(page.container)!;
  expect(element).not.toBeNull();
  expect(element.querySelector("[data-builtin]")!.textContent).toContain("no install needed");
  for (const key of [
    "computerUse.mode",
    "computerUse.deniedApps",
    "computerUse.menus",
    "computerUse.allowOwnMachines",
    "computerUse.pauseOnTakeover",
    "computerUse.showCursor",
    "computerUse.livePreview",
    "computerUse.allowForeground",
  ]) {
    expect(page.container.querySelectorAll(`[data-row-key="${key}"]`)).toHaveLength(1);
  }
  // The retired keys never show.
  expect(page.container.querySelector('[data-row-key="computerUse.enabled"]')).toBeNull();
  expect(page.container.querySelector('[data-row-key="computerUse.driver"]')).toBeNull();
  page.unmount();
});

test("the status shows the engine, each grant and the worker, and follows a change live", async () => {
  const page = await renderPage({ path: PATH });
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: ready }));
  await settle();
  const element = card(page.container)!;
  expect(element.textContent).toContain("cmux Computer Use 1.0");
  expect(grants(element)).toEqual(["true", "false"]);
  expect(element.querySelector('[data-worker="running"]')).not.toBeNull();
  // Only a missing grant offers Grant Access.
  expect(element.querySelector('[data-action="palette.computerUse.accessibility"]')).toBeNull();
  await act(async () =>
    element.querySelector<HTMLButtonElement>('[data-action="palette.computerUse.screenRecording"]')!.click(),
  );
  await settle();
  expect(ran(page.provider.log, "palette.computerUse.screenRecording")).toBe(true);
  await act(async () =>
    page.provider.setHost({ ...page.provider.host, computer_use: { ...ready, screen_recording: true } }),
  );
  await settle();
  expect(grants(card(page.container)!)).toEqual(["true", "true"]);
  expect(card(page.container)!.querySelector("[data-action^='palette.computerUse.']")).toBeNull();
  page.unmount();
});

test("the mode picker lists every mode with its line and writes computerUse.mode", async () => {
  const page = await renderPage({ path: PATH });
  await settle();
  const element = card(page.container)!;
  const modes = [...element.querySelectorAll<HTMLElement>("[data-mode]")];
  expect(modes.map((mode) => mode.dataset.mode)).toEqual([
    "fullAccess",
    "approvedApps",
    "askEveryTime",
    "lookOnly",
    "off",
  ]);
  expect(modes[0]!.dataset.checked).toBe("");
  expect(modes[0]!.textContent).toContain("any app except denied ones");
  expect(modes[1]!.textContent).toContain("Asks the first time each app is used");
  expect(modes[2]!.textContent).toContain("once per app in each agent session");
  expect(modes[3]!.textContent).toContain("No clicks or typing");
  await act(async () => modes[3]!.querySelector<HTMLInputElement>("input")!.click());
  await settle();
  expect(wrote(page.provider.log, "computerUse.mode", "lookOnly")).toBe(true);
  page.unmount();
});

test("off, the status says so and hides the grants", async () => {
  const page = await renderPage({ path: PATH, mock: { values: { "computerUse.mode": "off" } } });
  await act(async () => page.provider.setHost({ ...page.provider.host, computer_use: ready }));
  await settle();
  const element = card(page.container)!;
  expect(grants(element)).toEqual([]);
  expect(element.querySelector("[data-worker]")).toBeNull();
  expect(element.textContent).toContain("Computer Use is off");
  expect(element.querySelector<HTMLElement>('[data-mode="off"]')!.dataset.checked).toBe("");
  page.unmount();
});

test("the denied apps editor removes, adds by id or running app, and restores the defaults", async () => {
  const page = await renderPage({
    path: PATH,
    mock: { values: { "computerUse.deniedApps": ["com.apple.Terminal", "com.1password.*"] } },
  });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { ...ready, running_apps: [{ id: "com.figma.Desktop", name: "Figma" }] },
    }),
  );
  await settle();
  const element = card(page.container)!;
  const listed = () =>
    [...element.querySelectorAll<HTMLElement>("[data-denied-app]")].map((row) => row.dataset.deniedApp);
  expect(listed()).toEqual(["com.apple.Terminal", "com.1password.*"]);
  await act(async () =>
    element.querySelector<HTMLButtonElement>('[data-denied-app="com.apple.Terminal"] button')!.click(),
  );
  await settle();
  expect(wrote(page.provider.log, "computerUse.deniedApps", ["com.1password.*"])).toBe(true);
  const input = element.querySelector<HTMLInputElement>("[data-denied-input]")!;
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, "name:Notes");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => element.querySelector<HTMLButtonElement>("[data-denied-add]")!.click());
  await settle();
  expect(wrote(page.provider.log, "computerUse.deniedApps", ["com.1password.*", "name:Notes"])).toBe(true);
  // The running app is offered by the Add menu's form mirror.
  const select = element.querySelector<HTMLSelectElement>(".computer-use-add select")!;
  expect([...select.options].map((option) => option.value)).toContain("com.figma.Desktop");
  await act(async () => element.querySelector<HTMLButtonElement>("[data-denied-restore]")!.click());
  await settle();
  expect(
    page.provider.log.some(
      (entry) =>
        entry.op === "cmux.settings.reset" && (entry.params as { key: string }).key === "computerUse.deniedApps",
    ),
  ).toBe(true);
  page.unmount();
});

test("saved approvals change between Always Allow and Never, and Forget runs its action", async () => {
  const page = await renderPage({ path: PATH });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: {
        ...ready,
        approvals: [
          { app_id: "com.apple.Safari", name: "Safari", decision: "always" },
          { app_id: "com.apple.MobileSMS", name: "Messages", decision: "never" },
        ],
      },
    }),
  );
  await settle();
  const element = card(page.container)!;
  const safari = element.querySelector<HTMLElement>('[data-approval="com.apple.Safari"]')!;
  expect(safari.textContent).toContain("Always Allow");
  await act(async () => safari.querySelector<HTMLInputElement>('input[value="never"]')!.click());
  await settle();
  expect(ran(page.provider.log, "computerUse.approval.set", { app_id: "com.apple.Safari", decision: "never" })).toBe(
    true,
  );
  await act(async () => element.querySelector<HTMLButtonElement>('[data-forget="com.apple.MobileSMS"]')!.click());
  await settle();
  expect(ran(page.provider.log, "computerUse.approval.forget", { app_id: "com.apple.MobileSMS" })).toBe(true);
  expect(card(page.container)!.querySelector('[data-approval="com.apple.MobileSMS"]')).toBeNull();
  page.unmount();
});

test("the switches are schema rows and write their keys", async () => {
  const page = await renderPage({ path: PATH });
  await settle();
  const toggle = card(page.container)!.querySelector<HTMLButtonElement>(
    '[data-row-key="computerUse.allowForeground"] [role="switch"]',
  )!;
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  await act(async () => toggle.click());
  await settle();
  expect(wrote(page.provider.log, "computerUse.allowForeground", true)).toBe(true);
  page.unmount();
});

test("a failed worker offers Restart; a policy lock leaves no action", async () => {
  const page = await renderPage({ path: PATH });
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "failed", accessibility: null, screen_recording: null, helper: null },
    }),
  );
  await settle();
  await act(async () =>
    card(page.container)!.querySelector<HTMLButtonElement>('[data-action="palette.computerUse.restart"]')!.click(),
  );
  await settle();
  expect(ran(page.provider.log, "palette.computerUse.restart")).toBe(true);
  await act(async () =>
    page.provider.setHost({
      ...page.provider.host,
      computer_use: { phase: "disabled_by_policy", accessibility: null, screen_recording: null, helper: null },
    }),
  );
  await settle();
  const locked = card(page.container)!;
  expect(locked.dataset.phase).toBe("disabled_by_policy");
  expect(locked.querySelector("[data-action]")).toBeNull();
  expect(grants(locked)).toEqual([]);
  expect(locked.querySelector('[data-row-key="computerUse.mode"]')).not.toBeNull();
  page.unmount();
});
