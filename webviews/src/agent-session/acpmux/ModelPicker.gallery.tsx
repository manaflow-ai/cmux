// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ModelPickerProps } from "./modelPickerLayout";
import type { Play } from "../../gallery/play";
import { BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import { topModelsFor } from "./topModels";

const catalog: ModelPickerProps["catalog"] = [
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-opus-4-1", name: "Opus 4.1" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
    ],
  },
  {
    id: "codex",
    name: "Codex",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1-Sol" },
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
      { id: "gpt-6-luna", name: "GPT-6-Luna" },
      { id: "daybreak-blue", name: "Daybreak Blue" },
    ],
  },
  { id: "terminal", name: "Terminal", pickable: false, models: [{ id: "shell", name: "Shell" }] },
];

const refresh = (
  status: "idle" | "fetching" | "updated" | "error",
  date?: string,
): ModelPickerProps["catalogRefresh"] => ({
  status,
  date,
  refresh: () => undefined,
});

const base: ModelPickerProps = {
  catalog,
  harness: "claude",
  model: "claude-opus-5-5",
  label: "Opus 5.5",
  efforts: [],
  recents: [],
  onLand: () => undefined,
  onEffort: () => undefined,
};

/// The bundled catalog's Claude Code and Codex models with their curated top lists (topModels/):
/// the top models first, everything else under More models (cx-espus).
const curated: ModelPickerProps = {
  ...base,
  catalog: BUNDLED_MODEL_CATALOG.harnesses
    .filter((harness) => harness.id === "claude" || harness.id === "codex")
    .map((harness) => ({
      id: harness.id,
      name: harness.name,
      models: harness.models.map((model) => ({ id: model.id, name: model.name, shortName: model.shortName })),
      ...(topModelsFor(harness.id) ? { top: topModelsFor(harness.id) } : {}),
    })),
};

/// A machine with many agents installed (Lawrence 2026-10-13: the picker grew to the window's
/// height): each is its own harness profile, several of one brand (Claude Code, Claude Agent,
/// the subrouter and CodeRouter Claude routes).
const manyHarnesses: ModelPickerProps["catalog"] = [
  ...catalog.filter((entry) => entry.pickable !== false),
  ...[
    ["claude-acp", "Claude Agent"],
    ["claude-sr", "Claude (subrouter)"],
    ["claude-cr", "Claude (CodeRouter)"],
    ["cmux-codex", "cmux Codex"],
    ["gemini", "Gemini CLI"],
    ["opencode", "OpenCode"],
    ["pi", "Pi"],
    ["cursor", "Cursor"],
    ["kimi", "Kimi CLI"],
    ["amp-acp", "Amp"],
    ["goose", "goose"],
    ["qwen-code", "Qwen Code"],
    ["github-copilot-cli", "Copilot"],
    ["cline", "Cline"],
    ["auggie", "Auggie CLI"],
    ["junie", "Junie"],
    ["kilo", "Kilo"],
    ["mistral-vibe", "Mistral Vibe"],
    ["factory-droid", "Factory Droid"],
    ["devin", "Devin"],
    ["grok-build", "Grok Build"],
    ["deepagents", "DeepAgents"],
    ["poolside", "Poolside"],
    ["qoder", "Qoder CLI"],
  ].map(([id, name]) => ({ id: id!, name: name!, models: [{ id: `${id}-default`, name: "Default" }] })),
];

/// The open picker stays at most MODEL_PICKER_MAX_HEIGHT (480px) on a tall stage, and the rail
/// scrolls inside it instead of stretching the menu.
const cappedHeight: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => {
    const menu = ctx.document.querySelector<HTMLElement>(".acpmux-mp");
    const rail = ctx.document.querySelector<HTMLElement>(".acpmux-mp-rail-viewport");
    if (!menu || !rail || menu.style.visibility !== "visible") return false;
    const height = menu.getBoundingClientRect().height;
    return height > 300 && height <= 481 && rail.scrollHeight > rail.clientHeight + 100;
  });
};

const openModels: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-older") !== null);
};

const numericSearch: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  const search = { selector: '.acpmux-mp input[role="combobox"]' };
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-mp input[role="combobox"]') !== null);
  await ctx.type("gpt", search);
  await ctx.press("1");
  // With a query active, a digit is search input rather than a row shortcut. The menu remains
  // mounted after the key, whereas the old shortcut path selected the first cross-harness match
  // and closed the picker.
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-mp input[role="combobox"]') !== null);
};

export default componentEntry<ModelPickerProps>({
  id: "agent-pane.model-picker",
  title: "Model picker",
  area: "Agent pane",
  height: 390,
  widths: { narrow: 200, normal: 420, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: ["agent-session/acpmux/ModelPicker.tsx#ModelPicker", "ui/ScrollArea.tsx#ScrollArea"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () => import("./ModelPicker").then((module) => module.ModelPicker),
  variants: {
    idle: {
      props: { ...base, catalogRefresh: refresh("idle", "2026-10-07T10:00:00Z") },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
        await ctx.click({ role: "button", name: "Refresh models" });
      },
    },
    fetching: { props: { ...base, catalogRefresh: refresh("fetching", "2026-10-07T10:00:00Z") } },
    updated: { props: { ...base, catalogRefresh: refresh("updated", "2026-10-07T12:30:00Z") } },
    error: { props: { ...base, catalogRefresh: refresh("error", "2026-10-07T10:00:00Z") } },
    // An agent that has reported no models yet: the list says so and points at Refresh models.
    empty: {
      props: {
        ...base,
        catalog: catalog.map((entry) => (entry.id === "claude" ? { ...entry, models: [] } : entry)),
        model: undefined,
        label: "Claude Code",
        catalogRefresh: refresh("idle", "2026-10-07T10:00:00Z"),
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
      },
    },
    curated: { props: curated, play: openModels },
    "more-models": {
      props: curated,
      play: async (ctx) => {
        await openModels(ctx);
        await ctx.click({ selector: ".acpmux-mp-older" });
      },
    },
    // Many installed agents on a tall stage: the menu is capped and the harness rail scrolls.
    "many-harnesses": {
      props: { ...base, catalog: manyHarnesses },
      height: 1000,
      play: cappedHeight,
    },
    "numeric-search": {
      props: { ...base },
      play: numericSearch,
    },
    // A folder profile whose icon names no brand: the chip draws no mark (never a placeholder
    // square), and its rail tab its initial.
    "profile-without-mark": {
      props: {
        ...base,
        catalog: [
          {
            id: "vercel-ai-gateway",
            name: "Vercel AI Gateway",
            icon: "/icons/vercel-ai-gateway.svg",
            folder: { folder: "/Users/me/app", state: "enabled" },
            models: [{ id: "apex", name: "Apex" }],
          },
          ...catalog,
        ],
        harness: "vercel-ai-gateway",
        model: "apex",
        label: "Apex",
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
      },
    },
  },
});
