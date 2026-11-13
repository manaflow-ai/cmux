// The environment picker's Cloud row (Labs, cloudRun.ts): picking it makes Cloud where the new
// chat runs and hands the keyboard back to the prompt, on the first pick as on a repeat, so Return
// sends the draft. A machine picked after it makes the chat a chat here again.
import { afterEach, expect, test } from "bun:test";
import { act, useState, type ComponentProps } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { EnvironmentPicker } from "./EnvironmentPicker";
import type { RunMode } from "./sandboxRun";
import { translate } from "./i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

/// A new chat's composer: its prompt, and the picker with Run as rows the test can read back.
function Composer({ modes, picks, start }: { modes: RunMode[]; picks: string[]; start: RunMode }) {
  const [mode, setMode] = useState<RunMode>(start);
  return (
    <div className="nt-composer">
      <textarea aria-label="prompt" />
      <EnvironmentPicker
        label="Environment"
        menu="Computer"
        value="This Mac"
        face={<span>{mode === "cloud" ? "Cloud" : "This Mac"}</span>}
        environments={[
          { id: "local", label: "This Mac", kind: "local", connected: true },
          { id: "gpu-box", label: "gpu-box", kind: "ssh", connected: true },
        ]}
        current="local"
        onPick={(id) => picks.push(id)}
        runMode={{
          mode,
          onMode: (next) => {
            modes.push(next);
            setMode(next);
          },
        }}
      />
    </div>
  );
}

async function render(start: RunMode) {
  const container = installDom();
  const modes: RunMode[] = [];
  const picks: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(<Composer modes={modes} picks={picks} start={start} />);
  });
  return { container, modes, picks };
}

async function open(container: HTMLElement) {
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await settle();
}

/// The machine list: Machines… on the control's right-click menu (the main list is This Mac and Cloud).
async function openMachines(container: HTMLElement) {
  const button = container.querySelector<HTMLButtonElement>(".acpmux-location-button")!;
  await act(async () =>
    button.dispatchEvent(
      new dom!.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    ),
  );
  const item = [...document.querySelectorAll<HTMLElement>('[role="menu"] [role="menuitem"]')].find(
    (candidate) => candidate.textContent === translate("composer.machinesList"),
  );
  expect(item).toBeTruthy();
  await act(async () => item!.click());
  await settle();
}

async function choose(selector: string) {
  const row = document.querySelector<HTMLElement>(`.acpmux-env-popover ${selector}`);
  expect(row).not.toBeNull();
  const option = row!.closest<HTMLElement>('[role="option"]') ?? row!;
  await act(async () => option.click());
  await settle();
}

test("the Cloud row heads the Cloud section and picking it makes Cloud the mode and focuses the prompt", async () => {
  const { container, modes } = await render("persistent");
  await open(container);
  await choose('[data-mode="cloud"]');
  expect(modes).toEqual(["cloud"]);
  // The first pick too: the popover returns no focus, so Return would not reach the prompt.
  expect(document.activeElement).toBe(container.querySelector("textarea"));
  expect(container.querySelector(".acpmux-location-button")?.textContent).toBe("Cloud");
});

test("picking Cloud again changes nothing and still focuses the prompt", async () => {
  const { container, modes } = await render("cloud");
  await open(container);
  expect(document.querySelector('.acpmux-env-popover [data-mode="cloud"][data-current]')).not.toBeNull();
  await choose('[data-mode="cloud"]');
  expect(modes).toEqual([]);
  expect(document.activeElement).toBe(container.querySelector("textarea"));
});

test("a machine picked while Cloud is the mode makes the chat a chat here again", async () => {
  const { container, modes, picks } = await render("cloud");
  await openMachines(container);
  await choose('[data-kind="ssh"]');
  expect(modes).toEqual(["persistent"]);
  expect(picks).toEqual(["gpu-box"]);
});

// Other devices (Austin, 2026-11-12): a new chat's combined list has This Mac, Cloud and Other
// devices, whose count is the person's machines a chat can start on now; it opens those machines in
// place (no Cloud machine), each saying how it connects, then Add Machine….
const DEVICES = [
  { id: "local", label: "This Mac", kind: "local" as const, connected: true },
  { id: "studio", label: "studio", kind: "ssh" as const, connected: true },
  { id: "laptop", label: "laptop", kind: "ssh" as const, state: "connecting" },
  { id: "gpu-box", label: "gpu-box", kind: "ssh" as const, connected: true },
  { id: "vm-1", label: "vm-1", kind: "cloud" as const, connected: true },
];

async function renderDevices(
  environments: ComponentProps<typeof EnvironmentPicker>["environments"],
  props: Partial<ComponentProps<typeof EnvironmentPicker>> = {},
) {
  const container = installDom();
  const picks: string[] = [];
  const connects: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <div className="nt-composer">
        <textarea aria-label="prompt" />
        <EnvironmentPicker
          label="Environment"
          menu="Computer"
          value="This Mac"
          face={<span>This Mac</span>}
          environments={environments}
          current="local"
          onPick={(id) => picks.push(id)}
          onConnect={(kind) => connects.push(kind)}
          otherDevices
          {...props}
        />
      </div>,
    );
  });
  return { container, picks, connects };
}

const optionRows = () =>
  [...document.querySelectorAll<HTMLElement>('.acpmux-env-popover [role="option"]')].filter(
    (option) => option.querySelector(".acpmux-env-row") !== null,
  );
const rowLabel = (option: HTMLElement) => option.querySelector(".acpmux-menu-label")?.textContent ?? "";

test("Other devices follows Cloud with the count of the person's machines a chat can start on", async () => {
  const { container } = await renderDevices(DEVICES);
  await open(container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.thisMac"),
    translate("composer.cloud"),
    translate("composer.otherDevices"),
  ]);
  const row = document.querySelector('.acpmux-env-popover [data-action="otherDevices"]')!;
  // studio and gpu-box are ready; laptop is still connecting and vm-1 is a Cloud machine.
  expect(row.querySelector(".acpmux-env-count")?.textContent).toBe("2");
  expect(row.querySelector(".acpmux-env-more-chevron")).not.toBeNull();
});

test("Other devices with no machine still shows, with no count, and opens Add Machine…", async () => {
  const { container, connects } = await renderDevices([DEVICES[0]!, DEVICES[4]!]);
  await open(container);
  const row = document.querySelector('.acpmux-env-popover [data-action="otherDevices"]')!;
  expect(row.querySelector(".acpmux-env-count")).toBeNull();
  await choose('[data-action="otherDevices"]');
  expect(document.querySelector(".acpmux-env-popover .acpmux-env-heading")?.textContent).toBe(
    translate("composer.otherDevices"),
  );
  expect(optionRows().map(rowLabel)).toEqual([translate("composer.addMachine")]);
  await choose('[data-action="addMachine"]');
  expect(connects).toEqual(["addMachine"]);
});

test("Other devices opens the person's own machines, ready first, with how each connects and no Cloud machine", async () => {
  const { container, picks } = await renderDevices(DEVICES);
  await open(container);
  await choose('[data-action="otherDevices"]');
  expect(optionRows().map(rowLabel)).toEqual(["gpu-box", "studio", "laptop", translate("composer.addMachine")]);
  const ready = optionRows()[0]!;
  expect(ready.querySelector(".acpmux-menu-description")?.textContent).toBe(translate("composer.envSSH"));
  expect(ready.querySelector('.acpmux-env-status[data-connected="true"]')).not.toBeNull();
  // A machine still connecting is listed greyed with its state, and is no pick: the list stays open.
  const laptop = optionRows()[2]!;
  expect(laptop.querySelector('[data-ready="false"]')).not.toBeNull();
  await act(async () => laptop.click());
  await settle();
  expect(picks).toEqual([]);
  expect(document.querySelector(".acpmux-env-popover.acpmux-env-devices")).not.toBeNull();
  // A ready one is the pick, and the list closes.
  await choose('[data-kind="ssh"]');
  expect(picks).toEqual(["gpu-box"]);
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
});

test("a device picked stays checked in the main list", async () => {
  const picked = await renderDevices(DEVICES, { current: "studio" });
  await open(picked.container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.thisMac"),
    "studio",
    translate("composer.cloud"),
    translate("composer.otherDevices"),
  ]);
  expect(optionRows()[1]!.querySelector("[data-current]")).not.toBeNull();
});

test("without otherDevices (a started chat, the machine list) the main list has no Other devices row", async () => {
  const { container } = await renderDevices(DEVICES, { otherDevices: false });
  await open(container);
  expect(document.querySelector('.acpmux-env-popover [data-action="otherDevices"]')).toBeNull();
});
