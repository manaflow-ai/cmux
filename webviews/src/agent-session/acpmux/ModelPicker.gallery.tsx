// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ChatAccounts } from "./chatAccounts";
import type { ModelPickerProps } from "./modelPickerLayout";
import type { Play } from "../../gallery/play";
import { BUNDLED_MODEL_CATALOG } from "./modelCatalogData";
import { topModelsFor } from "./topModels";
import { type UpdateOffer, UpdateOfferContext } from "./HarnessHealthNotice";

/// The chat's agent CLI update on offer (hq#2569 #12), which the pane hands the chip by context.
type GalleryProps = ModelPickerProps & { update?: UpdateOffer };

const update: UpdateOffer = {
  harness: "claude",
  agent: "Claude Code",
  version: "2.1.4",
  latest: "2.2.0",
  update: () => undefined,
  skip: () => undefined,
};

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

/// The open picker stays at most MODEL_PICKER_MAX_HEIGHT (480px) on a tall stage, and its content
/// scrolls inside it (the harness rail) instead of stretching the menu.
const cappedHeight: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Model" });
  await ctx.waitFor(() => {
    const menu = ctx.document.querySelector<HTMLElement>(".acpmux-mp");
    if (!menu || menu.style.visibility !== "visible") return false;
    const height = menu.getBoundingClientRect().height;
    const scrolls = [menu, ...menu.querySelectorAll<HTMLElement>("*")].some(
      (node) => node.scrollHeight > node.clientHeight + 100,
    );
    return height > 300 && height <= 481 && scrolls;
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

/// The compact model menu, the one menu every composer's model button opens (Leo 2026-10-20):
/// numbered top models, then Effort, More models and Account beside their rows, then Fast mode.
const accounts: ChatAccounts = {
  list: async () => ({
    accounts: [
      { id: "max", name: "Claude Max", kind: "subscription" },
      { id: "api", name: "Anthropic API key", kind: "api-key" },
      { id: "subrouter", name: "subrouter", kind: "subrouter" },
    ],
    active: "max",
    scope: "chat",
  }),
  set: async () => undefined,
};

const quick: ModelPickerProps = {
  ...curated,
  quick: {
    effort: {
      levels: [
        { id: "low", name: "Low" },
        { id: "medium", name: "Medium" },
        { id: "high", name: "High" },
      ],
      current: "medium",
      onPick: () => undefined,
    },
    account: { sessionId: "gallery-chat", accounts },
    fast: { checked: false, onChange: () => undefined },
  },
};

/// The optional effort treatment Leo asked to compare: the default stays the Effort submenu, while
/// this variant uses the same stepped track with endpoint-inclusive thumb geometry.
const quickSlider: ModelPickerProps = {
  ...quick,
  quick: {
    ...quick.quick!,
    effort: { ...quick.quick!.effort!, slider: true, sliderStyle: "accent" },
  },
};

/// A started Claude chat that can fork, on a Mac with a second Claude account (its own profile).
const startedFork: ModelPickerProps = {
  ...quick,
  catalog: [
    ...curated.catalog,
    { ...curated.catalog.find((entry) => entry.id === "claude")!, id: "claude-work", name: "Claude (work)" },
  ],
  harnessFixed: true,
  fork: { to: () => undefined, ready: true },
};

const openQuick: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-model .acpmux-picker-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu") !== null);
};

const openQuickSlider: Play = async (ctx) => {
  await openQuick(ctx);
  // Base UI's submenu trigger opens on hover and ignores a plain mouse click; Enter on the
  // focused Effort row exercises the same path as keyboard users and keeps this capture reliable.
  await ctx.focus({ role: "menuitem", name: /^Effort/ });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-effort-slider .acpmux-effort-range") !== null);
};

/// An OpenCode chat as Lawrence's screenshot showed it (2026-10-22: "spacing + needs search"): one
/// model offered by several providers, each its own row.
const openCode: ModelPickerProps["catalog"] = [
  {
    id: "opencode",
    name: "OpenCode",
    models: [
      { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro [New]" },
      { id: "opencode/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "openrouter/deepseek/deepseek-v4.1-flash", name: "OpenRouter/DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-chat", name: "OpenRouter/DeepSeek Chat" },
      { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
      { id: "deepseek/deepseek-chat", name: "DeepSeek/DeepSeek Chat" },
      { id: "deepseek/deepseek-reasoner", name: "DeepSeek/DeepSeek Reasoner" },
      { id: "groq/deepseek-r2-distill", name: "Groq/DeepSeek R2 Distill" },
      { id: "anthropic/claude-sonnet-5-5", name: "Anthropic/Claude Sonnet 5.5" },
      { id: "openai/gpt-6.1-sol", name: "OpenAI/GPT-6.1-Sol" },
      { id: "zai/glm-5.3", name: "Z.ai/GLM 5.3" },
    ],
  },
];

const openCodeChat: ModelPickerProps = {
  ...quick,
  catalog: openCode,
  harness: "opencode",
  model: "opencode/deepseek-v4-pro",
  label: "DeepSeek V4 Pro",
  harnessFixed: true,
};

/// Harness menus have no fixed count. These fixture lists are supplied by the harness; an old
/// running or recent model stays under More models rather than changing its menu.
const relevantFew: ModelPickerProps = {
  ...base,
  catalog: [
    {
      id: "small-harness",
      name: "Small harness",
      top: ["swift", "careful"],
      models: [
        { id: "swift", name: "Swift" },
        { id: "careful", name: "Careful" },
        { id: "legacy", name: "Legacy" },
      ],
    },
  ],
  harness: "small-harness",
  model: "swift",
  label: "Swift",
  quick: {},
};
const relevantMany: ModelPickerProps = {
  ...base,
  catalog: [
    {
      id: "many-models",
      name: "Many models",
      top: ["model-0", "model-1", "model-2", "model-3", "model-4", "model-5"],
      models: [
        "Fast",
        "Balanced",
        "Reasoning",
        "Vision",
        "Small",
        "Code",
        "Older fast",
        "Older balanced",
        "Legacy",
      ].map((name, index) => ({ id: `model-${index}`, name })),
    },
  ],
  harness: "many-models",
  model: "model-7",
  label: "Older balanced",
  quick: {},
  recents: [{ harness: "many-models", model: "model-8" }],
};

// Actual live-probe menu order observed 2026-10-27. This account's Codex menu still offers
// older releases: preserve the harness's picker rather than inventing models the account lacks.
const reportedMenu = (id: string, name: string, entries: [string, string][]): ModelPickerProps => ({
  ...base,
  harness: id,
  model: entries[0]![0],
  label: entries[0]![1],
  quick: {},
  catalog: [
    {
      id,
      name,
      top: entries.map(([model]) => model),
      models: [...entries.map(([model, label]) => ({ id: model, name: label })), { id: "legacy", name: "Legacy" }],
    },
  ],
});
const reportedClaude = reportedMenu("claude", "Claude Code", [
  ["opus", "Opus 5.5"],
  ["fable", "Fable 5.1"],
  ["sonnet", "Sonnet 5.5"],
  ["haiku", "Haiku 5.5"],
]);
const reportedCodex = reportedMenu("codex", "Codex", [
  ["gpt-6.1-sol", "GPT-6.1-Sol"],
  ["gpt-6-astra", "GPT-6-Astra"],
  ["gpt-6-sol", "GPT-6-Sol"],
  ["gpt-6-luna", "GPT-6-Luna"],
  ["gpt-5.6-sol", "GPT-5.6-Sol"],
  ["gpt-5.6-terra", "GPT-5.6-Terra"],
  ["gpt-5.6-luna", "GPT-5.6-Luna"],
  ["gpt-5.5", "GPT-5.5"],
]);

/// The search field's versions (Lawrence 2026-10-22: "spacing + needs search"): `always` ships.
const searchLook = (props: ModelPickerProps, searchField: "always" | "typed" | "long"): ModelPickerProps => ({
  ...props,
  quick: { ...props.quick, searchField },
});

const searchField = { selector: ".acpmux-quick-search input" };
const typeSearch =
  (text: string): Play =>
  async (ctx) => {
    await openQuick(ctx);
    await ctx.waitFor(() => ctx.document.querySelector(searchField.selector) !== null);
    await ctx.type(text, searchField);
    await ctx.waitFor(
      () => ctx.document.querySelector(".acpmux-quick-menu .ui-menu-group-label")?.textContent === `“${text}”`,
    );
  };

export default componentEntry<GalleryProps>({
  id: "agent-pane.model-picker",
  title: "Model picker",
  area: "Agent pane",
  pane: true,
  height: 390,
  widths: { narrow: 200, normal: 420, wide: 760 },
  anchors: [{ selector: ".acpmux-model" }],
  covers: [
    "agent-session/acpmux/ModelPicker.tsx#ModelPicker",
    "agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu",
    "ui/ScrollArea.tsx#ScrollArea",
    "agent-session/acpmux/HarnessHealthNotice.tsx#UpdateOfferContext",
  ],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./composerControls.css")]),
  load: () =>
    import("./ModelPicker").then(({ ModelPicker }) => ({ update: offer, ...props }: GalleryProps) => (
      <UpdateOfferContext.Provider value={offer}>
        <ModelPicker {...props} />
      </UpdateOfferContext.Provider>
    )),
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
      // An empty list never collapses the menu to its search field (Lawrence 2026-10-13).
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-mp");
          return !!menu && menu.style.visibility === "visible" && menu.getBoundingClientRect().height >= 219;
        });
      },
    },
    curated: { props: curated, play: openModels },
    // A Codex chat with a message (Leo 2026-10-19): its harness is fixed, so the menu is search,
    // Codex's models and More models, with no harness rail and no Add harness….
    "started-chat": {
      props: {
        ...curated,
        harness: "codex",
        model: "gpt-6.1-sol",
        label: "GPT-6.1 Sol",
        harnessFixed: true,
        onAddAgent: () => undefined,
      },
      play: openModels,
    },
    // The same chat on the compact menu: Codex's numbered models with no rail.
    "started-chat-quick-menu": {
      props: {
        ...quick,
        harness: "codex",
        model: "gpt-6.1-sol",
        label: "GPT-6.1 Sol",
        harnessFixed: true,
        onAddAgent: () => undefined,
      },
      play: openQuick,
    },
    // The same chat where it can fork (Leo 2026-10-22: "can expose as fork"): the whole rail, and
    // the Codex tab offers Fork to Codex in place of its models.
    "started-chat-fork": {
      props: startedFork,
      play: async (ctx) => {
        await openQuick(ctx);
        await ctx.click({ selector: '.acpmux-quick-rail-tab[aria-label="Codex"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-fork") !== null);
      },
    },
    // Its Account row contains signed-in routes, separate from named launch harnesses.
    "started-chat-accounts": {
      props: startedFork,
      play: async (ctx) => {
        await openQuick(ctx);
        await ctx.click({ role: "menuitem", name: /^Account/ });
        await ctx.waitFor(() =>
          Array.from(ctx.document.querySelectorAll('[role="menuitemradio"]')).some(
            (row) => row.textContent === "Anthropic API key",
          ),
        );
      },
    },
    // Three captures keep the menu comparison concrete: default Effort submenu, opt-in slider, and
    // the harness-only rail with no machine/session initials.
    "quick-menu": { props: quick, play: openQuick },
    "relevant-few": { props: relevantFew, play: openQuick },
    "relevant-many": { props: relevantMany, play: openQuick },
    "reported-claude-menu": { props: reportedClaude, play: openQuick },
    "reported-codex-menu": { props: reportedCodex, play: openQuick },
    // An agent CLI update on offer: a quiet footer below the model choices, out of the numbered list.
    "quick-update-offer": { props: { ...quick, update }, play: openQuick },
    // The same footer on a started chat's menu, which has no rail.
    "started-chat-update-offer": {
      props: {
        ...quick,
        harness: "codex",
        model: "gpt-6.1-sol",
        label: "GPT-6.1 Sol",
        harnessFixed: true,
        update,
      },
      play: openQuick,
    },
    "quick-menu-slider": { props: quickSlider, play: openQuickSlider },
    // A new chat with a named alternate launch harness and separate account routes.
    "quick-menu-accounts": {
      props: { ...quick, catalog: startedFork.catalog, onHarness: () => undefined },
      play: async (ctx) => {
        await openQuick(ctx);
        await ctx.click({ role: "menuitem", name: /^Account/ });
        await ctx.waitFor(() =>
          Array.from(ctx.document.querySelectorAll('[role="menuitemradio"]')).some(
            (row) => row.textContent === "Anthropic API key",
          ),
        );
      },
    },
    // The rail's Codex tab: Codex's models in place; Effort and Account stay with the chat's harness.
    "quick-menu-rail": {
      props: quick,
      play: async (ctx) => {
        await openQuick(ctx);
        await ctx.click({ selector: '.acpmux-quick-rail-tab[aria-label="Codex"]' });
        await ctx.waitFor(
          () => ctx.document.querySelector('.acpmux-quick-rail-tab[aria-label="Codex"][aria-pressed="true"]') !== null,
        );
      },
    },
    // Search, version A (ships): a search field heads the list and has the keyboard as the menu
    // opens, so the menu says it can search (Lawrence: "needs search").
    "quick-search-field": {
      note: "Search version A (ships): the field heads the list and has the keyboard when the menu opens.",
      props: searchLook(quick, "always"),
      play: openQuick,
    },
    "quick-search-field-typed": {
      note: "Search version A, typed: the full picker's matching, an effort word included; Enter lands the first row with it.",
      props: searchLook(quick, "always"),
      play: typeSearch("opus high"),
    },
    "quick-search-field-opencode": {
      note: "Search version A on Lawrence's OpenCode chat: typing narrows its long provider list.",
      props: searchLook(openCodeChat, "always"),
      play: typeSearch("deepseek v4"),
    },
    // Version B: no field until a key is typed (Claude Code's menu), then the field shows the query.
    "quick-search-typed-only": {
      note: "Search version B: no field until you type, as in Claude Code; nothing says the menu searches.",
      props: searchLook(quick, "typed"),
      play: openQuick,
    },
    "quick-search-typed-only-typing": {
      note: "Search version B after typing on a row: the field appears with the query.",
      props: searchLook(quick, "typed"),
      play: async (ctx) => {
        await openQuick(ctx);
        // A key on a row opens the field with it; the rest types into the field.
        await ctx.press("s");
        await ctx.waitFor(() => ctx.document.querySelector(searchField.selector) !== null);
        await ctx.type("on", searchField);
        await ctx.waitFor(
          () => ctx.document.querySelector(".acpmux-quick-menu .ui-menu-group-label")?.textContent === "“son”",
        );
      },
    },
    // Version C: a field only on a long list (more than eight models), else as B.
    "quick-search-long-list": {
      note: "Search version C: OpenCode's twelve models get a field.",
      props: searchLook(openCodeChat, "long"),
      play: openQuick,
    },
    "quick-search-long-short-list": {
      note: "Search version C: a short model list gets none, so the same menu changes shape by harness.",
      props: searchLook({ ...quick, catalog, harnessFixed: true }, "long"),
      play: openQuick,
    },
    // Typing filters every harness's models in place, each row naming its harness.
    "quick-menu-filter": { props: quick, play: typeSearch("son") },
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
    // The agent CLI is outdated: a dot on the chip, and Update and Skip This Version in the
    // picker, never a banner over the chat (hq#2569 #12).
    "update-offer": {
      props: { ...base, update },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-update") !== null);
      },
    },
    "numeric-search": {
      props: { ...base },
      play: numericSearch,
    },
    // Codex is signed out on this Mac (cx-ae9eb): its rail tab dims, and its list offers Log In in
    // place of models, so a pick never starts a chat that fails its first turn.
    "signed-out": {
      props: { ...base, signedOut: { codex: "codex login" }, onLogIn: () => undefined },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Model" });
        await ctx.click({ selector: ".acpmux-mp-harness[data-signed-out]" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mp-login") !== null);
      },
    },
    // A folder profile is a machine choice, not a harness: it remains the selected model source,
    // while the rail contains only Claude/Codex harnesses.
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
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-mp-harness")].every(
            (tab) => tab.getAttribute("title")?.split(" · ")[0] !== "Vercel AI Gateway",
          ),
        );
      },
    },
  },
});
