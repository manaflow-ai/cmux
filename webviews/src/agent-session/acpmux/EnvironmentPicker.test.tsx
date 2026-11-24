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

// A new chat's list (Leo, 2026-11-23: "another chevron, just like how cloud goes to another chevron";
// "i think so. i think this is good as a start."): Auto, Cloud only, Machine…, which cascades BESIDE the
// list with This Mac and the person's own machines (acpmux `group` own). An agent machine (group agent)
// is no place of a new chat. Add Machine… ends the cascade.
const DEVICES = [
  { id: "local", label: "This Mac", kind: "local" as const, connected: true },
  { id: "studio", label: "studio", kind: "ssh" as const, connected: true, group: "own" as const },
  { id: "laptop", label: "laptop", kind: "ssh" as const, state: "connecting", group: "own" as const },
  { id: "gpu-box", label: "gpu-box", kind: "ssh" as const, connected: true, group: "own" as const, liveSessions: 3 },
  {
    id: "lane-1",
    label: "gcp-agent-lane-1",
    kind: "ssh" as const,
    connected: true,
    group: "agent" as const,
    liveSessions: 2,
  },
  { id: "lane-2", label: "gcp-agent-lane-2", kind: "ssh" as const, connected: true, group: "agent" as const },
  { id: "lane-3", label: "gcp-agent-lane-3", kind: "ssh" as const, state: "offline", group: "agent" as const },
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

const optionRows = (scope = ".acpmux-env-popover") =>
  [...document.querySelectorAll<HTMLElement>(`${scope} [role="option"]`)].filter(
    (option) => option.querySelector(".acpmux-env-row") !== null,
  );
const rowLabel = (option: HTMLElement) => option.querySelector(".acpmux-menu-label")?.textContent ?? "";
const cascadeRows = () => optionRows(".acpmux-env-cascade");

// A new chat's list: Cloud is where it may run, and Auto heads it (`runMode`).
const NEW_CHAT = autoChat(false, []);

test("the list is Auto, Cloud only, Machine…: no machine, count or Agent machines in it", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.auto"),
    translate("composer.cloudOnly"),
    translate("composer.machineMenu"),
  ]);
  expect(document.querySelector(".acpmux-env-count")).toBeNull();
  expect(document.querySelector(".acpmux-env-popover")!.textContent).not.toContain("gcp-agent-lane");
});

test("Auto picked is checked, Machine… has a chevron, Cloud only none", async () => {
  const { container } = await renderDevices(DEVICES, autoChat(true, []));
  await open(container);
  const [auto, cloud, machine] = optionRows();
  expect(auto!.querySelector("[data-current]")).not.toBeNull();
  expect(cloud!.querySelector("[data-current]")).toBeNull();
  expect(machine!.querySelector("[data-current]")).toBeNull();
  expect(machine!.querySelector(".acpmux-env-more-chevron")).not.toBeNull();
  expect(cloud!.querySelector(".acpmux-env-more-chevron")).toBeNull();
});

test("⌥⌘1–3 number Auto, Cloud only and Machine…; a ready own machine takes ⌥⌘4 and up; an agent machine never", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  const keys = optionRows().map((row) => row.querySelector(".acpmux-env-key")?.textContent ?? "");
  expect(keys).toEqual(["⌥⌘1", "⌥⌘2", "⌥⌘3"]);
  await choose('[data-action="machineMenu"]');
  const own = cascadeRows().map((row) => [rowLabel(row), row.querySelector(".acpmux-env-key")?.textContent ?? ""]);
  expect(own).toEqual([
    [translate("composer.thisMac"), ""],
    ["gpu-box", "⌥⌘4"],
    ["studio", "⌥⌘5"],
    ["laptop", ""],
    [translate("composer.addMachine"), ""],
  ]);
});

test("the cascade says live sessions when acpmux says so, never SSH", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  await choose('[data-action="machineMenu"]');
  const descriptions = cascadeRows().map((row) => row.querySelector(".acpmux-menu-description")?.textContent ?? "");
  expect(descriptions[1]).toBe(translate("composer.envLive", { n: 3 }));
  expect(descriptions.join(" ")).not.toContain(translate("composer.envSSH"));
});

test("Machine… opens beside the list: the list stays; This Mac, the own machines (never an agent one), Add Machine…", async () => {
  const { container, picks } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  await choose('[data-action="machineMenu"]');
  expect(optionRows().map(rowLabel)).toContain(translate("composer.auto"));
  expect(document.querySelector(".acpmux-env-cascade")).not.toBeNull();
  expect(cascadeRows().map(rowLabel)).toEqual([
    translate("composer.thisMac"),
    "gpu-box",
    "studio",
    "laptop",
    translate("composer.addMachine"),
  ]);
  // The parent stays clickable: Cloud only there closes everything.
  await act(async () =>
    optionRows()
      .find((row) => rowLabel(row) === translate("composer.cloudOnly"))!
      .click(),
  );
  await settle();
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
  expect(picks).toEqual([]);
});

test("a pick in the Machine… cascade is the machine's pick and leaves Auto", async () => {
  const log: string[] = [];
  const { container, picks } = await renderDevices(DEVICES, autoChat(true, log));
  await open(container);
  await choose('[data-action="machineMenu"]');
  await act(async () =>
    cascadeRows()
      .find((row) => rowLabel(row) === "gpu-box")!
      .click(),
  );
  await settle();
  expect(picks).toEqual(["gpu-box"]);
  expect(log).toContain("auto:false");
  expect(document.querySelector(".acpmux-env-popover")).toBeNull();
});

test("a manual pick unchecks Auto and checks Machine… and the machine; Auto picked again picks it", async () => {
  const chosen: string[] = [];
  const { container } = await renderDevices(DEVICES, { ...autoChat(false, chosen), current: "gpu-box" });
  await open(container);
  const [auto, , machine] = optionRows();
  expect(auto!.querySelector("[data-current]")).toBeNull();
  expect(machine!.querySelector("[data-current]")).not.toBeNull();
  await choose('[data-action="machineMenu"]');
  expect(
    cascadeRows()
      .find((row) => rowLabel(row) === "gpu-box")!
      .querySelector("[data-current]"),
  ).not.toBeNull();
  await act(async () => optionRows()[0]!.click());
  await settle();
  expect(chosen).toEqual(["auto:true"]);
});

test("← and Escape go back one level: the cascade closes, the list stays", async () => {
  const { container } = await renderDevices(DEVICES, NEW_CHAT);
  await open(container);
  const key = async (target: Element, name: string) =>
    act(async () => {
      target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
  await choose('[data-action="machineMenu"]');
  const field = () => document.querySelector<HTMLInputElement>(".acpmux-env-cascade input")!;
  await key(field(), "ArrowLeft");
  await settle();
  expect(document.querySelector(".acpmux-env-cascade")).toBeNull();
  expect(document.querySelector(".acpmux-env-popover")).not.toBeNull();
  await choose('[data-action="machineMenu"]');
  await key(field(), "Escape");
  await settle();
  expect(document.querySelector(".acpmux-env-cascade")).toBeNull();
  expect(document.querySelector(".acpmux-env-popover")).not.toBeNull();
});

test("Cloud only is one plain row: no cascade, no size or provider rows; a click picks Cloud", async () => {
  const modes: string[] = [];
  const { container } = await renderDevices(DEVICES, {
    runMode: { mode: "persistent" as RunMode, onMode: (mode) => modes.push(mode) },
  });
  await open(container);
  const cloud = document.querySelector<HTMLElement>('.acpmux-env-popover [data-mode="cloud"]')!;
  expect(cloud.getAttribute("data-cascade")).toBeNull();
  await act(async () => cloud.dispatchEvent(new dom!.window.Event("pointerover", { bubbles: true })));
  await settle();
  expect(document.querySelector(".acpmux-env-cascade")).toBeNull();
  await choose('[data-mode="cloud"]');
  expect(modes).toEqual(["cloud"]);
});

test("the own machines' cascade searches once they are many; an agent machine is never found", async () => {
  const many = [
    ...DEVICES,
    ...Array.from({ length: 8 }, (_, i) => ({
      id: `own-${i}`,
      label: `own-box-${i}`,
      kind: "ssh" as const,
      connected: true,
      group: "own" as const,
    })),
  ];
  const { container } = await renderDevices(many, NEW_CHAT);
  await open(container);
  await choose('[data-action="machineMenu"]');
  const field = document.querySelector<HTMLInputElement>(".acpmux-env-cascade input")!;
  const type = async (text: string) => {
    await act(async () => {
      const set = Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!;
      set.call(field, text);
      field.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
    });
    await settle();
  };
  await type("own-box-3");
  expect(cascadeRows().map(rowLabel)).toEqual(["own-box-3"]);
  await type("gcp-agent");
  expect(cascadeRows()).toEqual([]);
});

test("with no own machine Machine… still opens, with This Mac and Add Machine…", async () => {
  const { container, connects } = await renderDevices([DEVICES[0]!, DEVICES[7]!], NEW_CHAT);
  await open(container);
  await choose('[data-action="machineMenu"]');
  expect(cascadeRows().map(rowLabel)).toEqual([translate("composer.thisMac"), translate("composer.addMachine")]);
  await choose('[data-action="addMachine"]');
  expect(connects).toEqual(["addMachine"]);
});

test("without otherDevices (a started chat, the machine list) the main list has no Machine… row", async () => {
  const { container } = await renderDevices(DEVICES, { otherDevices: false });
  await open(container);
  expect(document.querySelector('.acpmux-env-popover [data-action="machineMenu"]')).toBeNull();
  expect(document.querySelector('.acpmux-env-popover [data-kind="auto"]')).toBeNull();
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

test("Auto heads a new chat's list only when the page offers it", async () => {
  const offered = await renderDevices(DEVICES, autoChat(false, []));
  await open(offered.container);
  expect(optionRows().map(rowLabel)).toEqual([
    translate("composer.auto"),
    translate("composer.thisMac"),
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
