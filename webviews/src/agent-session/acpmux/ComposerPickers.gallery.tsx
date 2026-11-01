// l10n-allow-file: gallery fixtures exercise picker states and labels, not shipped copy.
import { useEffect, useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { ComposerPickers } from "./ComposerPickers";
import { BUNDLED_MODEL_CATALOG, buildPickerCatalog } from "./modelCatalogData";
import { ChatAccountsContext, readChatAccounts, type ChatAccounts } from "./chatAccounts";
import { rememberFullAccess } from "./startMode";

/// The chat's accounts: its CLI login alone, as Leo's chat had (the Account row names it).
const galleryAccounts: ChatAccounts = {
  list: async () => ({ accounts: [] }),
  set: async () => undefined,
};

/** `claude`: Leo's started claude-sr2 chat (2026-10-21), whose model menu listed nine models. */
/** `managed`: acpmux answered `"fullAccess": "managed"` (MDM keeps full access off, #23322). */
type Props = { claude?: boolean; accounts?: boolean; managed?: boolean };

const directAccounts: ChatAccounts = {
  list: async () =>
    readChatAccounts({
      routes: [
        { id: "personal", name: "Personal", kind: "direct-subscription", serves: true },
        { id: "work", name: "Work API", kind: "direct-api-key", serves: true },
        { id: "codex", name: "Codex account", kind: "direct-subscription", serves: false },
        ...["subrouter", "cliproxyapi", "custom-anthropic", "custom-openai", "local-coderouter", "cmux-router"].map(
          (kind) => ({ id: kind, name: kind, kind, serves: true }),
        ),
      ],
      active: { routeId: "personal", scope: "chat" },
      family: "claude",
    }),
  set: async () => undefined,
};

/// Claude Code's model list as Leo's chat reported it: its aliases named as the releases they run,
/// its 1M and plan modes, and Fable 5.1 pinned. The chat runs the pinned release claude-opus-5-5
/// on claude-sr2, a Claude Code profile the model catalog does not map; Claude Code's `opus` is the
/// same model, so the menu lists it once.
const claudeCodeModels = [
  { id: "default", name: "Default (recommended)" },
  { id: "opus", name: "Opus 5.5" },
  { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
  { id: "sonnet", name: "Sonnet 5.5" },
  { id: "haiku", name: "Haiku 5.5" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet[1m]", name: "Sonnet · 1M context" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
];

const claudeSnapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "gallery",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [{ id: "claude-sr2", name: "Claude Code", family: "claude-sr2", models: claudeCodeModels }],
  summary: {
    sessionId: "gallery-claude",
    harness: "claude-sr2",
    family: "claude-sr2",
    model: "claude-opus-5-5",
    turnCount: 12,
    usage: { used: 300_000, size: 1_000_000 },
    modes: {
      availableModes: [
        { id: "default", name: "Default" },
        { id: "acceptEdits", name: "Accept edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
      currentModeId: "default",
    },
    configOptions: [
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: "claude-opus-5-5",
        options: claudeCodeModels.map((model) => ({ value: model.id, name: model.name })),
      },
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "medium",
        options: ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value, name: value })),
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

const codexSnapshot: AcpmuxSnapshot = {
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
          inlineFast: true,
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

function GalleryComposerPickers({ claude, accounts, managed }: Props) {
  // As an acpmux answer would set it; cleared again when the variant goes.
  useEffect(() => {
    rememberFullAccess(managed ? "managed" : undefined);
    return () => rememberFullAccess(undefined);
  }, [managed]);
  const initialSnapshot = claude ? claudeSnapshot : codexSnapshot;
  const [model, setModel] = useState(initialSnapshot.summary!.model!);
  const [mode, setMode] = useState(initialSnapshot.summary!.modes!.currentModeId!);
  const [effort, setEffort] = useState("medium");
  const [fast, setFast] = useState("off");
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
    [initialSnapshot, effort, fast, mode, model],
  );
  // The model catalog's join, as the agent pane builds it, so Claude Code's aliases fold.
  const pickerCatalog = useMemo(
    () =>
      claude
        ? buildPickerCatalog({
            catalog: BUNDLED_MODEL_CATALOG,
            acpmux: snapshot.catalog,
            session: {
              harness: "claude-sr2",
              model: snapshot.summary?.model,
              configOptions: snapshot.summary?.configOptions,
            },
          })
        : undefined,
    [claude, snapshot],
  );
  return (
    <ChatAccountsContext.Provider value={accounts ? directAccounts : galleryAccounts}>
      <div className="acpmux-composer-gallery-shell">
        <div className="acpmux-composer-gallery-copy">
          <strong>Composer controls</strong>
          <span>One model button (model and effort), permission, and Plan controls share one quiet footer rail.</span>
        </div>
        <ComposerPickers
          snapshot={snapshot}
          {...(pickerCatalog ? { pickerCatalog } : {})}
          onModel={setModel}
          onMode={setMode}
          onEffort={(id, value) => (id === "fast-mode" ? setFast(value) : setEffort(value))}
          showPlan
        />
      </div>
    </ChatAccountsContext.Provider>
  );
}

// The model button opens its one menu (Leo 2026-10-20): numbered models, then Effort, More models
// and Fast mode. The full picker (the search) is its More models row; Fast is always a toggle row.
const MODEL = { role: "button", name: "Model" } as const;
const quickRows = '.acpmux-quick-menu [role="menuitemradio"]';

const openModel: Play = async (ctx) => {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(quickRows) !== null);
  if (ctx.document.querySelector(".acpmux-fast")) throw new Error("the composer must draw no Fast bolt");
  if (!ctx.document.querySelector(".acpmux-quick-menu .acpmux-quick-fast"))
    throw new Error("the compact model menu has no Fast mode toggle");
  const headers = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu .ui-menu-group-label")];
  if (headers.some((node) => node.textContent?.trim()))
    throw new Error("the compact model menu should not show a static session header");
};

const openAccounts: Play = async (ctx) => {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(quickRows) !== null);
  await ctx.focus({ role: "menuitem", name: /^Account/ });
  await ctx.press("Enter");
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-quick-menu")].some(
      (menu) => menu.textContent?.includes("Personal") && !menu.querySelector(".acpmux-quick-sub"),
    ),
  );
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
  // Onto its name: the row's trailing columns hold its effort item, which opens the levels instead.
  const row = {
    selector: ".acpmux-quick-model-effort[data-running] > .acpmux-quick-item .acpmux-quick-label",
  } as const;
  await ctx.pointer.move(row);
  await ctx.pointer.up(row);
  await ctx.waitFor(
    () => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === ctx.find(MODEL),
  );
};

// The current model's effort is a side dropdown beside its row (#27948): its effort item opens the
// model's levels in a submenu of their own.
const RUNNING_EFFORT = ".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger";
/// The checked level in that dropdown.
const CHECKED_EFFORT = '.acpmux-quick-effort-menu .acpmux-quick-effort-segment[aria-checked="true"]';

/// Opens the model menu, then the running model's effort dropdown; resolves with the dropdown.
async function openEffortMenu(ctx: Parameters<Play>[0]): Promise<HTMLElement> {
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(RUNNING_EFFORT) !== null);
  // A submenu trigger opens on hover or from the keyboard: focus it and press ArrowRight.
  await ctx.focus({ selector: RUNNING_EFFORT });
  await ctx.press("ArrowRight");
  let levels: HTMLElement | undefined;
  await ctx.waitFor(() => {
    levels = ctx.document.querySelector<HTMLElement>(".acpmux-quick-effort-menu") ?? undefined;
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
  const checked = levels.querySelector<HTMLElement>('[aria-checked="true"]')!;
  await ctx.focus({ selector: CHECKED_EFFORT });
  await ctx.waitFor(() => ctx.document.activeElement === checked);
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => {
    const highlighted = ctx.document.querySelector(".acpmux-quick-menu [data-highlighted]");
    return highlighted !== null && highlighted !== checked;
  });
  // The first Escape closes the effort dropdown back to its row; the next closes the menu.
  await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-quick-effort-menu"));
  if (ctx.document.querySelector('[role="menu"]')) await ctx.press("Escape");
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]') && ctx.document.activeElement === trigger);
};

const effortPick: Play = async (ctx) => {
  const levels = await openEffortMenu(ctx);
  const high = [...levels.querySelectorAll<HTMLElement>(".acpmux-quick-effort-segment")].find(
    (segment) => (segment.querySelector(".acpmux-menu-label")?.textContent ?? segment.textContent)?.trim() === "High",
  );
  if (!high) throw new Error("the current model's effort control offers no High");
  await ctx.click({ selector: `.acpmux-quick-menu [aria-label="${high.getAttribute("aria-label")}"]` });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".acpmux-model .acpmux-model-detail:not(.acpmux-fit-label)")?.textContent === "High",
  );
};

const fastMode: Play = async (ctx) => {
  const fast = { selector: ".acpmux-quick-menu .acpmux-quick-fast" } as const;
  await ctx.click(MODEL);
  await ctx.waitFor(() => ctx.document.querySelector(fast.selector) !== null);
  if (ctx.document.querySelector(".acpmux-fast")) throw new Error("the composer must draw no Fast bolt");
  if (ctx.find(fast).getAttribute("aria-checked") !== "false") throw new Error("Fast mode must start off");
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
  if (ctx.document.querySelector(".acpmux-access-heading"))
    throw new Error("the permission menu should not show a static header");
  const labels = [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitemradio"] .acpmux-menu-label')].map(
    (node) => node.textContent?.trim(),
  );
  // Plan is the separate composer toggle; this menu contains permission modes only.
  const expected = ["Default", "Full access"];
  if (labels.length !== expected.length || labels.some((label, index) => label !== expected[index]))
    throw new Error(`Permission mode titles are not in menu order: ${labels.join(" | ")}`);
  for (const [index, item] of [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].entries()) {
    if (item.querySelector(".ui-menu-check")?.parentElement !== item)
      throw new Error("Permission mode checkmark is not in its leading column");
    if (item.querySelector<HTMLElement>(".ui-menu-shortcut")?.textContent?.trim() !== String(index + 1))
      throw new Error("Permission mode shortcut is not a trailing hint");
  }
};

const managedMode: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"][aria-checked="true"]') !== null);
  const row = [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find((item) =>
    item.textContent?.includes("Full access"),
  );
  if (row?.getAttribute("aria-disabled") !== "true") throw new Error("Full access must be disabled while managed");
  if (row.querySelector(".acpmux-menu-description")?.textContent?.trim() !== "Managed by your organization")
    throw new Error("Full access must say it is managed by the organization");
};

// The mode menu lists the modes alone (Leo, 2026-10-29): granted access is revoked from the chat
// menu's Revoke Granted Access (header/grantsMenu.ts), never from this menu.
const modesOnly: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Mode" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menuitemradio"]') !== null);
  if (ctx.document.querySelector(".acpmux-access-grants, .acpmux-access-grant"))
    throw new Error("The mode menu shows granted access");
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
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ComposerPickers", "agent-session/acpmux/QuickModelMenu.tsx"],
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
      note: "The model button opens its one menu: this harness's models, numbered, then Effort, More models and the Fast mode toggle.",
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
      note: "The current model's row carries its effort levels inline, the current one checked; there is no Effort submenu or separate effort chip.",
      props: {},
      play: openEffort,
    },
    "effort-focus": {
      note: "From the current effort, arrow navigation moves the highlight; Escape closes the menu and restores focus to Model.",
      props: {},
      play: effortFocus,
    },
    // The id predates the one button; its point stays: a pick of High lands and the button names it.
    "effort-press-drag-release": {
      note: "Picking High in the current model's inline effort closes the menu, and the model button then reads High after the model.",
      props: {},
      play: effortPick,
    },
    "claude-model-menu": {
      note: "Leo's started claude-sr2 chat (2026-10-21; nine numbered rows, Opus 5.5 twice): the menu lists four models, Opus 5.5 once and checked; Effort names Medium, Account names CLI login, Fast mode names Off, and the rest are under More models.",
      props: { claude: true },
      play: openModel,
    },
    "claude-direct-accounts": {
      height: 580,
      note: "Account lists the local harness login and its two direct accounts; compatible proxy and router transports stay out of the list.",
      props: { claude: true, accounts: true },
      play: openAccounts,
    },
    "claude-effort-up": {
      note: "Opened from the composer at the window's foot, the menu grows up with the current model's inline effort, Medium checked (Leo 2026-10-21: the Effort submenu opened downward; #26521 folds it into the row).",
      props: { claude: true },
      play: openEffort,
    },
    "fast-mode": {
      note: "Fast mode is the model picker’s toggle row: a click turns it on without adding a separate composer control; every non-off tier stays checked.",
      props: {},
      play: fastMode,
    },
    "permission-menu": { props: {}, play: openMode },
    "permission-managed": {
      note: "MDM keeps full access off (#23322): Full access is disabled and says Managed by your organization; the other rows are unchanged.",
      props: { managed: true },
      play: managedMode,
    },
    "modes-only": {
      note: "The mode menu lists the modes alone: no Granted access section (Leo, 2026-10-29); grants are revoked from the chat menu's Revoke Granted Access.",
      props: {},
      play: modesOnly,
    },
    "permission-focus": {
      note: "The numeric mode shortcut picks Full access; Escape from a reopen returns focus to Mode.",
      props: {},
      play: modeFocus,
    },
    plan: { props: {}, play: planToggle },
  },
});
