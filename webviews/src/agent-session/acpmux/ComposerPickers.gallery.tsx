// l10n-allow-file: gallery fixtures exercise picker states and labels, not shipped copy.
import { useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers, type ComposerPermissionGrant } from "./ComposerPickers";

type Props = Record<string, never>;

const initialSnapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "gallery",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [
    {
      id: "codex",
      name: "Codex",
      models: [
        {
          id: "gpt-6.1-sol",
          name: "GPT-6.1 Sol",
          efforts: ["low", "medium", "high"],
          defaultEffort: "medium",
          fast: true,
          contextWindow: 200_000,
        },
        { id: "gpt-6-astra", name: "GPT-6 Astra", efforts: ["low", "high"] },
      ],
    },
    {
      id: "claude",
      name: "Claude Code",
      models: [{ id: "claude-sonnet-5-5", name: "Sonnet 5.5", efforts: ["medium", "high"] }],
    },
  ],
  summary: {
    sessionId: "gallery-composer",
    harness: "codex",
    model: "gpt-6.1-sol",
    turnCount: 1,
    usage: { used: 48_000, size: 200_000 },
    modes: {
      availableModes: [
        { id: "default", name: "Default", description: "Ask before sensitive actions." },
        { id: "full-access", name: "Full access", description: "Run actions without asking." },
        { id: "plan", name: "Plan", description: "Read and propose without editing." },
      ],
      currentModeId: "default",
    },
    configOptions: [
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "medium",
        options: [
          { value: "low", name: "Low" },
          { value: "medium", name: "Medium" },
          { value: "high", name: "High" },
        ],
      },
      {
        id: "fast-mode",
        name: "Fast mode",
        currentValue: "off",
        options: [
          { value: "off", name: "Off" },
          { value: "on", name: "On" },
        ],
      },
      // Codex still reports this option for its /plan command and mode paths; the footer leaves it
      // out of the generic Options chip.
      {
        id: "collaboration_mode",
        name: "Collaboration mode",
        category: "collaboration_mode",
        currentValue: "default",
        options: [
          { value: "default", name: "Default" },
          { value: "plan", name: "Plan", description: "Write a plan before editing." },
        ],
      },
    ],
  },
};

function GalleryComposerPickers() {
  const [model, setModel] = useState(initialSnapshot.summary!.model!);
  const [mode, setMode] = useState(initialSnapshot.summary!.modes!.currentModeId!);
  const [effort, setEffort] = useState("medium");
  const [fast, setFast] = useState("off");
  const [grants, setGrants] = useState<ComposerPermissionGrant[]>([
    { id: "folder", label: "Trusted cmux-tui", onRemove: () => setGrants((current) => current.slice(1)) },
    { id: "git-grep", label: "Allow git grep in cmux for this session", onRemove: () => setGrants([]) },
  ]);
  const snapshot = useMemo<AcpmuxSnapshot>(
    () => ({
      ...initialSnapshot,
      summary: {
        ...initialSnapshot.summary!,
        model,
        modes: { ...initialSnapshot.summary!.modes!, currentModeId: mode },
        configOptions: initialSnapshot.summary!.configOptions!.map((option) => ({
          ...option,
          currentValue: option.id === "effort" ? effort : option.id === "fast-mode" ? fast : option.currentValue,
        })),
      },
    }),
    [effort, fast, mode, model],
  );
  return (
    <div className="acpmux-composer-gallery-shell">
      <div className="acpmux-composer-gallery-copy">
        <strong>Composer controls</strong>
        <span>One model button (model and effort), permission, and Plan controls share one quiet footer rail.</span>
      </div>
      <ComposerPickers
        snapshot={snapshot}
        permissionAccess={{ grants }}
        onModel={setModel}
        onMode={setMode}
        onEffort={(id, value) => (id === "fast-mode" ? setFast(value) : setEffort(value))}
        showPlan
      />
    </div>
  );
}

// The model button opens its one menu (Leo 2026-10-20): numbered models, then Effort, More models
// and Fast mode. The full picker (the search) is its More models row.
const MODEL = { role: "button", name: "Model" } as const;
const quickRows = '.acpmux-quick-menu [role="menuitemradio"]';

const openModel: Play = async (ctx) => {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(quickRows) !== null);
  if (!ctx.document.querySelector(".acpmux-quick-menu .acpmux-quick-fast"))
    throw new Error("the model menu has no Fast mode row");
};

const modelFocus: Play = async (ctx) => {
  const trigger = ctx.find(MODEL);
  await ctx.click(MODEL);
  await ctx.waitFor(() => {
    const menu = ctx.document.querySelector(".acpmux-quick-menu");
    return menu !== null && menu.contains(ctx.document.activeElement);
  });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu [data-highlighted]") !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger);
};

const modelPressDragRelease: Play = async (ctx) => {
  await ctx.pointer.down(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu") !== null);
  await ctx.waitFor(() => {
    const popup = ctx.document.querySelector<HTMLElement>(".acpmux-quick-menu");
    if (!popup) return false;
    const rect = popup.getBoundingClientRect();
    return (
      rect.width > 0 && rect.height > 0 && ctx.document.defaultView?.getComputedStyle(popup).visibility !== "hidden"
    );
  });
  // Astra may sit under More models in this fixture: drag to the current model's row, which still
  // exercises the button's press-drag-release path and closes the menu.
  const row = { role: "menuitemradio", name: /GPT-6\.1 Sol/ } as const;
  await ctx.pointer.move(row);
  await ctx.pointer.up(row);
  await ctx.waitFor(
    () => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === ctx.find(MODEL),
  );
};

/// Opens the model menu's Effort submenu; resolves with its popup.
async function openEffortMenu(ctx: Parameters<Play>[0]): Promise<HTMLElement> {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(quickRows) !== null);
  // A submenu row opens on hover or from the keyboard: Base UI's submenu trigger ignores a mouse
  // press while it opens on hover. Enter on the focused row opens it, as a keyboard user does.
  await ctx.focus({ role: "menuitem", name: /^Effort/ });
  await ctx.press("Enter");
  let levels: HTMLElement | undefined;
  await ctx.waitFor(() => {
    // The submenu is the quick menu with no submenu rows of its own.
    levels = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")].find(
      (menu) => !menu.querySelector(".acpmux-quick-sub") && menu.querySelector('[role="menuitemradio"]') !== null,
    );
    return levels;
  });
  return levels!;
}

const openEffort: Play = async (ctx) => {
  const levels = await openEffortMenu(ctx);
  await ctx.waitFor(() => levels.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
};

const effortFocus: Play = async (ctx) => {
  const trigger = ctx.find(MODEL);
  const levels = await openEffortMenu(ctx);
  await ctx.waitFor(() => levels.contains(ctx.document.activeElement));
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => levels.querySelector('[role="menuitemradio"][data-highlighted]') !== null);
  await ctx.press("Escape");
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger);
};

const effortPick: Play = async (ctx) => {
  await openEffortMenu(ctx);
  await ctx.click({ role: "menuitemradio", name: /^High/ });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-model .acpmux-model-detail:not(.acpmux-fit-label)")?.textContent === "High",
  );
};

const fastMode: Play = async (ctx) => {
  await ctx.click(MODEL);
  const fast = { selector: ".acpmux-quick-menu .acpmux-quick-fast" } as const;
  await ctx.waitFor(() => ctx.document.querySelector(fast.selector) !== null);
  if (ctx.find(fast).getAttribute("aria-checked") !== "false") throw new Error("Fast mode must start off");
  // A checkbox row keeps the menu open, so the row shows the confirmed state in place.
  await ctx.click(fast);
  await ctx.waitFor(() => ctx.document.querySelector(fast.selector)?.getAttribute("aria-checked") === "true");
};

const morePicker: Play = async (ctx) => {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(quickRows) !== null);
  await ctx.click({ role: "menuitem", name: /^More models/ });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [type="search"]') !== null);
};

const openMode: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
  const labels = [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitemradio"] .acpmux-menu-label')].map(
    (node) => node.textContent?.trim(),
  );
  const expected = ["Default", "Full access", "Plan"];
  if (labels.length !== expected.length || labels.some((label, index) => label !== expected[index]))
    throw new Error(`Permission mode titles are not in menu order: ${labels.join(" | ")}`);
  for (const [index, item] of [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].entries()) {
    if (item.querySelector(".ui-menu-check")?.parentElement !== item)
      throw new Error("Permission mode checkmark is not in its leading column");
    if (item.querySelector<HTMLElement>(".ui-menu-shortcut")?.textContent?.trim() !== String(index + 1))
      throw new Error("Permission mode shortcut is not a trailing hint");
  }
};

const accessGrants: Play = async (ctx) => {
  const trigger = ctx.find({ role: "button", name: "Mode" });
  if (trigger.textContent?.includes("Trusted")) throw new Error("Trust state leaked into the Access trigger");
  // The allowed rules live in the menu only; the trigger shows no count beside the mode.
  if (trigger.querySelector(".acpmux-access-grant-count") || /\d/.test(trigger.textContent ?? ""))
    throw new Error("Access trigger shows an allowed-rule count");
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-access-grants") !== null);
  const grants = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-access-grant")];
  if (grants.length !== 2) throw new Error(`Expected two allowed rules, found ${grants.length}`);
  if (!grants.every((row) => row.querySelector(".acpmux-access-grant-remove")))
    throw new Error("Allowed rules must each have a remove button");
  await ctx.click({ selector: ".acpmux-access-grant-remove" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-access-grant").length === 1);
  await ctx.press("Escape");
};

const modeFocus: Play = async (ctx) => {
  const trigger = ctx.find({ role: "button", name: "Mode" });
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
  await ctx.press("2");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger);
};

const planToggle: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Build" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Plan" }).getAttribute("aria-pressed") === "true");
};

export default componentEntry<Props>({
  id: "agent-pane.composer-pickers",
  title: "Composer picker rail",
  area: "Agent pane",
  pane: true,
  height: 260,
  // Keep the narrow stage below the model picker's 407px column-layout breakpoint.
  widths: { narrow: 400, normal: 640, wide: 860 },
  anchors: [{ selector: ".acpmux-chips" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Opening a picker must leave the composer rail in place." },
    layoutShiftMax: { value: 0, reason: "Picker surfaces are portaled and must not add flow to the composer." },
    longFrameFailMs: { value: 33, reason: "Composer picker actions should remain responsive on the gallery host." },
    settleMaxMs: { value: 250, reason: "Local picker opens and toggles should settle within a quarter second." },
  },
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers"],
  load: async () => GalleryComposerPickers,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./composerControls.css"),
      import("./modelPicker.css"),
      import("./ComposerPickers.gallery.css"),
    ]),
  variants: {
    closed: { props: {} },
    "pill-rail": {
      note: "The 400 px Codex rail keeps model, effort and access quiet; its reported collaboration mode has no footer control.",
      props: {},
    },
    "model-menu": {
      note: "The model button opens its one menu: this harness's models, numbered, then Effort, More models and Fast mode.",
      props: {},
      play: openModel,
    },
    "model-more": {
      note: "More models opens the full picker with its search, the only way to it from the button.",
      props: {},
      play: morePicker,
    },
    "model-focus": {
      note: "The model menu owns focus while open; Escape closes it and restores focus to Model.",
      props: {},
      play: modelFocus,
    },
    "model-press-drag-release": {
      note: "Pressing Model, dragging onto a model row, and releasing picks the row and closes the menu.",
      props: {},
      play: modelPressDragRelease,
    },
    "effort-menu": {
      note: "The model menu's Effort row opens the levels beside it, the current one checked; there is no separate effort chip.",
      props: {},
      play: openEffort,
    },
    "effort-focus": {
      note: "Arrow navigation moves the highlighted effort; Escape twice closes both menus and restores focus to Model.",
      props: {},
      play: effortFocus,
    },
    // The id predates the one button; its point stays: a pick of High lands and the button names it.
    "effort-press-drag-release": {
      note: "Picking High in the Effort submenu closes the menu, and the model button then reads High after the model.",
      props: {},
      play: effortPick,
    },
    "fast-mode": {
      note: "Fast mode is the model menu's last row, a checkbox (Leo 2026-10-20): a click turns it on, and the menu shows it checked.",
      props: {},
      play: fastMode,
    },
    "permission-menu": { props: {}, play: openMode },
    "access-grants": {
      note: "Allowed folder and chat rules stay inside Access; the footer shows only a compact count and the menu offers removal.",
      props: {},
      play: accessGrants,
    },
    "permission-focus": {
      note: "The numeric mode shortcut picks Full access; Escape from a reopen returns focus to Mode.",
      props: {},
      play: modeFocus,
    },
    plan: { props: {}, play: planToggle },
  },
});
