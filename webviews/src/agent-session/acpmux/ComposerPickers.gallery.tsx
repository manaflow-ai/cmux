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
        <span>Model, context, effort, permission, and Plan controls share one quiet footer rail.</span>
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

const openModel: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [type="search"]') !== null);
};

const modelFocus: Play = async (ctx) => {
  const trigger = ctx.find({ role: "button", name: "Model" });
  const search = { selector: '.acpmux-mp input[role="combobox"]' };
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"] [type="search"]') !== null);
  await ctx.waitFor(() => ctx.document.activeElement === ctx.find(search));
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => Boolean(ctx.find(search).getAttribute("aria-activedescendant")));
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="dialog"]') && ctx.document.activeElement === trigger);
};

const modelPressDragRelease: Play = async (ctx) => {
  await ctx.pointer.down({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]') !== null);
  await ctx.waitFor(() => {
    const popup = ctx.document.querySelector<HTMLElement>('[role="dialog"]');
    if (!popup) return false;
    const rect = popup.getBoundingClientRect();
    return (
      rect.width > 0 && rect.height > 0 && ctx.document.defaultView?.getComputedStyle(popup).visibility !== "hidden"
    );
  });
  // Astra is folded under Older models in this fixture. Drag to the visible current model row;
  // the gesture still exercises the picker trigger's press-drag-release path without inventing a
  // click on a row that is not mounted.
  const visibleModel = '[role="option"][data-key="model:gpt-6.1-sol"]';
  await ctx.pointer.move({ selector: visibleModel });
  await ctx.pointer.up({ selector: visibleModel });
  await ctx.waitFor(
    () =>
      !ctx.document.querySelector('[role="dialog"]') &&
      ctx.document.activeElement === ctx.find({ role: "button", name: "Model" }),
  );
};

const openEffort: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
};

const effortFocus: Play = async (ctx) => {
  const trigger = ctx.find({ role: "button", name: "Effort" });
  await ctx.click({ role: "button", name: "Effort" });
  await ctx.waitFor(() => {
    const selected = ctx.document.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]');
    return selected !== null && ctx.document.activeElement === selected;
  });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][data-highlighted]') !== null);
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger);
};

const effortPressDragRelease: Play = async (ctx) => {
  await ctx.pointer.down({ role: "button", name: "Effort" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
  await ctx.pointer.move({ text: "High" });
  await ctx.pointer.up({ text: "High" });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(
    () => ctx.document.querySelector(".acpmux-effort .acpmux-picker-button > span")?.textContent === "High",
  );
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
    if (item.querySelector(".ui-menu-check"))
      throw new Error("Permission mode rows should not render a leading checkmark");
    if (item.querySelector<HTMLElement>(".ui-menu-shortcut")?.textContent?.trim() !== String(index + 1))
      throw new Error("Permission mode shortcut is not a trailing hint");
  }
  if (document.querySelectorAll('[role="menuitemradio"][aria-checked="true"]').length !== 1)
    throw new Error("Permission mode selection state is not exposed through aria-checked");
};

const accessGrants: Play = async (ctx) => {
  const trigger = ctx.find({ role: "button", name: "Mode" });
  if (trigger.textContent?.includes("Trusted")) throw new Error("Trust state leaked into the Access trigger");
  if (!trigger.querySelector(".acpmux-access-grant-count"))
    throw new Error("Access trigger is missing the compact allowed-rule count");
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
    "model-menu": { props: {}, play: openModel },
    "model-focus": {
      note: "The model search owns focus while open; Escape closes it and restores focus to Model.",
      props: {},
      play: modelFocus,
    },
    "model-press-drag-release": {
      note: "Pressing Model, dragging onto a model row, and releasing picks the row and closes the picker.",
      props: {},
      play: modelPressDragRelease,
    },
    "effort-menu": { props: {}, play: openEffort },
    "effort-focus": {
      note: "Arrow navigation moves the highlighted effort; Escape closes the menu and restores Effort focus.",
      props: {},
      play: effortFocus,
    },
    "effort-press-drag-release": {
      note: "Pressing Effort, dragging onto High, and releasing picks the row and closes the menu.",
      props: {},
      play: effortPressDragRelease,
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
