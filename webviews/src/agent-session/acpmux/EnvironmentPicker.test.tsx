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
import { settleReact } from "../../../test/support/domTeardown";

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
  await settleReact();
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

// A new chat's list: Cloud is where it may run (`runMode`).
const NEW_CHAT = { runMode: { mode: "persistent" as RunMode, onMode: () => undefined } };

test("Other devices follows Cloud with the count of the person's machines a chat can start on", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.thisMac"),
    translate("composer.cloud"),
    translate("composer.otherDevices"),
  ]);
  const row = document.querySelector('.acpmux-env-popover [data-action="otherDevices"]')!;
  // studio and gpu-box are ready and laptop is still dialing (a pick too); vm-1 is a Cloud machine.
  expect(row.querySelector(".acpmux-env-count")?.textContent).toBe("3");
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
  // A machine still connecting is never greyed and says no state (Leo, 2026-11-24: "all the
  // connecting... indicators and the graying out of workspaces, nah let's not do that"): it is a pick,
  // and the chat starts once its link is up.
  const laptop = optionRows()[2]!;
  expect(laptop.querySelector('[data-ready="false"]')).toBeNull();
  expect(laptop.textContent).not.toContain(translate("machineLink.connecting"));
  await act(async () => laptop.click());
  await settle();
  expect(picks).toEqual(["laptop"]);
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
});

test("a device picked stays checked in the main list", async () => {
  const picked = await renderDevices(DEVICES, { current: "studio", ...NEW_CHAT });
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

// cmux#47677: the Where menu's Cloud row with no run-mode rows (before the host's check answered, a
// chat Cloud isn't offered to) ran New Cloud Machine, which made a machine and a workspace on the
// click. Picking Cloud now makes nothing: no connect, no machine pick.
test("Cloud with no run mode makes nothing: no New Cloud Machine, no machine pick", async () => {
  // A page on its Cloud machine: the row is where the chat runs, and picking it makes nothing.
  const { container, connects, picks } = await renderDevices(DEVICES, { current: "vm-1" });
  await open(container);
  await choose('[data-kind="cloud"]');
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
  expect(connects).toEqual([]);
  expect(picks).toEqual([]);
});

test("with no run mode and the chat not on Cloud, the list offers no Cloud row that would do nothing", async () => {
  const { container, connects } = await renderDevices(DEVICES);
  await open(container);
  expect(
    document.querySelector('.acpmux-env-popover [data-action="cloud"], .acpmux-env-popover [data-kind="cloud"]'),
  ).toBeNull();
  expect(connects).toEqual([]);
});

// Auto (autoWhereModel.ts; Leo, 2026-11-22: "the selection for auto as an environment choice between
// cloud/local/whatever is the whole point"): a new chat's first row when the page offers it.
function autoChat(picked: boolean, log: string[], mode: RunMode = "persistent") {
  return {
    runMode: {
      mode,
      onMode: (next: RunMode) => void log.push(`mode:${next}`),
      auto: { picked, onPick: (on: boolean) => void log.push(`auto:${on}`), look: "orbit" as const },
    },
  };
}

// cmux#51731: This Mac, Auto, Cloud, Other devices, so Auto reads as the step between the two.
test("Auto sits between This Mac and Cloud in a new chat's list only when the page offers it", async () => {
  const offered = await renderDevices(DEVICES, autoChat(false, []));
  await open(offered.container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.thisMac"),
    translate("composer.auto"),
    translate("composer.cloud"),
    translate("composer.otherDevices"),
  ]);
  const row = document.querySelector('.acpmux-env-popover [data-kind="auto"]')!;
  expect(row.getAttribute("data-auto-look")).toBe("orbit");
  expect(row.querySelector('.acpmux-auto-icon[data-look="orbit"]')).not.toBeNull();
  expect(row.querySelector("[data-current]")).toBeNull();
});

test("the list has no Auto row without the page's offer", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  expect(optionRows().map(rowLabel)).not.toContain(translate("composer.auto"));
});

test("picking Auto turns it on, closes the list and focuses the prompt", async () => {
  const log: string[] = [];
  const { container } = await renderDevices(DEVICES, autoChat(false, log));
  await open(container);
  await choose('[data-kind="auto"]');
  expect(log).toEqual(["auto:true"]);
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
  expect(document.activeElement).toBe(container.querySelector("textarea"));
});

test("Auto picked is the one checked row, and the chip carries its look", async () => {
  const { container } = await renderDevices(DEVICES, autoChat(true, []));
  expect(container.querySelector(".acpmux-location-picker")?.getAttribute("data-auto-look")).toBe("orbit");
  await open(container);
  const checked = [...document.querySelectorAll(".acpmux-env-popover .acpmux-env-row[data-current]")];
  expect(checked.map((row) => row.getAttribute("data-kind"))).toEqual(["auto"]);
});

test("with Auto picked, This Mac turns Auto off and the chat stays here", async () => {
  const local: string[] = [];
  const here = await renderDevices(DEVICES, autoChat(true, local));
  await open(here.container);
  await choose('[data-kind="local"]');
  expect(local).toEqual(["auto:false"]);
  // This Mac was already the machine: no machine pick, the prompt takes focus.
  expect(here.picks).toEqual([]);
  expect(document.activeElement).toBe(here.container.querySelector("textarea"));
});

test("with Auto picked, Cloud turns Auto off and makes Cloud the mode", async () => {
  const log: string[] = [];
  const { container } = await renderDevices(DEVICES, autoChat(true, log));
  await open(container);
  await choose('[data-mode="cloud"]');
  expect(log).toEqual(["auto:false", "mode:cloud"]);
});

// AutoCloud (Leo, 2026-11-24: "let's just use our existing dropdown and have it be able to have a
// chevron that opens into more options"): with the hidden cloud.autoCloud key and an active plan, the
// page marks Auto `cloud`, and Auto's row is a chevron that opens Auto ⌥⌘1, Cloud only ⌥⌘2, Machine… ⌥⌘3.
function autoCloudChat(picked: boolean, log: string[], mode: RunMode = "persistent") {
  const chat = autoChat(picked, log, mode);
  return { runMode: { ...chat.runMode, auto: { ...chat.runMode.auto, cloud: true } } };
}

const autoKey = async (digit: number) => {
  await act(async () =>
    window.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { code: `Digit${digit}`, altKey: true, metaKey: true, bubbles: true }),
    ),
  );
  await settle();
};

test("AutoCloud: Auto's row is a chevron that opens Auto, Cloud only and Machine… with their keys", async () => {
  const { container } = await renderDevices(DEVICES, autoCloudChat(false, []));
  await open(container);
  const row = document.querySelector('.acpmux-env-popover [data-action="autoPlaces"]')!;
  expect(row.querySelector(".acpmux-env-more-chevron")).not.toBeNull();
  expect(optionRows().map(rowLabel)[1]).toBe(translate("composer.auto"));
  await choose('[data-action="autoPlaces"]');
  expect(document.querySelector(".acpmux-env-auto-places")).not.toBeNull();
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.auto"),
    translate("composer.autoCloudOnly"),
    translate("composer.autoMachine"),
  ]);
  expect([...document.querySelectorAll(".acpmux-env-popover .acpmux-env-key")].map((key) => key.textContent)).toEqual([
    "⌥⌘1",
    "⌥⌘2",
    "⌥⌘3",
  ]);
});

test("AutoCloud: picking Auto in its list turns Auto on and focuses the prompt", async () => {
  const log: string[] = [];
  const { container } = await renderDevices(DEVICES, autoCloudChat(false, log));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  await choose('[data-action="autoPlace"]');
  expect(log).toEqual(["auto:true"]);
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
  expect(document.activeElement).toBe(container.querySelector("textarea"));
});

test("AutoCloud: ⌥⌘1 in the open Auto list picks Auto, not This Mac", async () => {
  const log: string[] = [];
  const { container, picks } = await renderDevices(DEVICES, autoCloudChat(false, log));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  await autoKey(1);
  expect(log).toEqual(["auto:true"]);
  expect(picks).toEqual([]);
});

test("AutoCloud: Cloud only (⌥⌘2) turns Auto off and makes Cloud the mode", async () => {
  const log: string[] = [];
  const { container } = await renderDevices(DEVICES, autoCloudChat(true, log));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  expect(document.querySelector('.acpmux-env-popover [data-action="autoPlace"][data-current]')).not.toBeNull();
  await autoKey(2);
  expect(log).toEqual(["auto:false", "mode:cloud"]);
});

test("AutoCloud: Machine… opens the person's other devices in place", async () => {
  const { container } = await renderDevices(DEVICES, autoCloudChat(false, []));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  await choose('[data-action="machine"]');
  expect(document.querySelector(".acpmux-env-devices")).not.toBeNull();
  expect(optionRows().map(rowLabel)).toContain("studio");
});

// Leo, 2026-11-24: "i cant click back". Every list opened in place heads with a row back to the list
// it opened from; ← with no search typed does the same.
test("AutoCloud: the Auto list's heading goes back to the main list, and Machine…'s back to Auto", async () => {
  const { container } = await renderDevices(DEVICES, autoCloudChat(false, []));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  await choose('[data-action="machine"]');
  expect(document.querySelector(".acpmux-env-devices")).not.toBeNull();
  await choose('[data-action="back"]');
  expect(document.querySelector(".acpmux-env-auto-places")).not.toBeNull();
  expect(optionRows().map(rowLabel)[1]).toBe(translate("composer.autoCloudOnly"));
  await choose('[data-action="back"]');
  expect(document.querySelector(".acpmux-env-auto-places")).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-action="back"]')).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-action="autoPlaces"]')).not.toBeNull();
});

test("← in a list opened in place goes back to the one it opened from", async () => {
  const { container } = await renderDevices(DEVICES, autoCloudChat(false, []));
  await open(container);
  await choose('[data-action="autoPlaces"]');
  const field = document.querySelector<HTMLElement>(".acpmux-env-popover .acpmux-location-search")!;
  await act(async () =>
    field.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true, cancelable: true }),
    ),
  );
  await settle();
  expect(document.querySelector(".acpmux-env-auto-places")).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-action="autoPlaces"]')).not.toBeNull();
});

test("Other devices heads with a way back to the main list", async () => {
  const { container } = await renderDevices(DEVICES);
  await open(container);
  await choose('[data-action="otherDevices"]');
  await choose('[data-action="back"]');
  expect(document.querySelector(".acpmux-env-devices")).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-action="otherDevices"]')).not.toBeNull();
});

test("Machines… heads with a way back to the main list", async () => {
  const { container } = await render("persistent");
  await openMachines(container);
  expect(document.querySelector('.acpmux-env-popover [data-kind="ssh"]')).not.toBeNull();
  await choose('[data-action="back"]');
  expect(document.querySelector('.acpmux-env-popover [data-action="back"]')).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-kind="ssh"]')).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-mode="cloud"]')).not.toBeNull();
});

test("Move to… heads with a way back to the main list", async () => {
  const { container } = await renderDevices(DEVICES.slice(0, 1), {
    otherDevices: false,
    onOffload: () => undefined,
    offload: "move",
    moveTargets: [
      { id: "vm-dev", label: "dev-box", kind: "cloud" },
      { id: "vm-gpu", label: "gpu-box", kind: "cloud" },
    ],
    onMoveTo: () => undefined,
  });
  await open(container);
  await choose('[data-action="moveTo"]');
  expect(document.querySelector(".acpmux-env-moves")).not.toBeNull();
  await choose('[data-action="back"]');
  expect(document.querySelector(".acpmux-env-moves")).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-action="moveTo"]')).not.toBeNull();
});

test("AutoCloud gated off: Auto stays the one plain row, with no chevron", async () => {
  const { container } = await renderDevices(DEVICES, autoChat(false, []));
  await open(container);
  expect(document.querySelector('.acpmux-env-popover [data-action="autoPlaces"]')).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-kind="auto"] .acpmux-env-more-chevron')).toBeNull();
});

// A started chat's Move to… list opens on where the chat runs now, checked: the person sees what
// they are moving from. Picking that row moves nothing and closes the list.
test("Move to… lists where the chat runs now, checked, before its targets; picking it moves nothing", async () => {
  const moves: string[] = [];
  const { container, picks } = await renderDevices(DEVICES.slice(0, 1), {
    otherDevices: false,
    onOffload: () => undefined,
    offload: "move",
    moveTargets: [
      { id: "vm-dev", label: "dev-box", kind: "cloud" },
      { id: "vm-gpu", label: "gpu-box", kind: "cloud" },
    ],
    onMoveTo: (id) => moves.push(id),
  });
  await open(container);
  await choose('[data-action="moveTo"]');
  expect(optionRows().map(rowLabel)).toEqual(["This Mac", "dev-box", "gpu-box"]);
  const here = document.querySelector<HTMLElement>('.acpmux-env-moves [data-action="moveHere"]')!;
  expect(here.hasAttribute("data-current")).toBe(true);
  expect(here.querySelector(".acpmux-location-check svg")).not.toBeNull();
  expect(document.querySelectorAll(".acpmux-env-moves [data-current]").length).toBe(1);
  await choose('[data-action="moveHere"]');
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
  expect(moves).toEqual([]);
  expect(picks).toEqual([]);
});

test("a target picked from Move to… still moves the chat there", async () => {
  const moves: string[] = [];
  const { container } = await renderDevices(DEVICES.slice(0, 1), {
    otherDevices: false,
    onOffload: () => undefined,
    offload: "move",
    moveTargets: [
      { id: "vm-dev", label: "dev-box", kind: "cloud" },
      { id: "vm-gpu", label: "gpu-box", kind: "cloud" },
    ],
    onMoveTo: (id) => moves.push(id),
  });
  await open(container);
  await choose('[data-action="moveTo"]');
  await choose('[data-action="moveTarget"]');
  expect(moves).toEqual(["vm-dev"]);
});

// cmux#51745: the Environment dropdown resizes as the model menu does, from its edges away from the
// chip, and keeps its size for every composer.
test("the Environment dropdown has resize grips on its edges away from the chip and opens at its kept size", async () => {
  const { setPopupSize } = await import("../../ui/PopupResize");
  setPopupSize("composer.environment", { width: 300, height: 220 });
  try {
    const { container } = await render("persistent");
    await open(container);
    const popup = document.querySelector<HTMLElement>(".acpmux-env-popover")!;
    expect(popup).not.toBeNull();
    const side = popup.dataset.side === "bottom" ? "bottom" : "top";
    expect(popup.querySelector('.ui-popup-resize[data-axis="y"]')?.getAttribute("data-side")).toBe(side);
    expect(popup.querySelector('.ui-popup-resize[data-axis="x"]')?.getAttribute("data-edge")).toBe("end");
    expect(popup.querySelector('.ui-popup-resize[data-axis="both"]')).not.toBeNull();
    expect(popup.style.width).toContain("300px");
    expect(popup.style.height).toContain("220px");
  } finally {
    setPopupSize("composer.environment", { width: undefined, height: undefined });
  }
});
