// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// The compact model menu as the New Tab page draws it (newTabComposer.ts): it opens down, has no
// heading and no key hints, and More models shows a tab's other models in place. The OpenCode tab
// has no Effort, Account or Fast mode rows and a long More models list.
import React, { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { QuickFamily, QuickMenu } from "./QuickModelMenu";

type Props = {
  tab?: string;
  expand?: boolean;
  chat?: boolean;
  fast?: boolean;
  many?: boolean;
  placement?: "symbols" | "left" | "top" | "compact";
  stress?: boolean;
  /** Opt in to the inline effort segments used by the focused layout fixture. */
  inlineEffort?: boolean;
  anchorTop?: boolean;
  anchorMiddle?: boolean;
  routeLayout?: QuickMenu["routeLayout"];
  widthLook?: QuickMenu["widthLook"];
  /** Leo's rail: Claude Code with claude-sr2 and a work login, Codex with its app server and an SR route. */
  routes?: boolean;
};

const models = (family: string, names: string[]) =>
  names.map((name) => ({
    id: `${family}/${name}`,
    name,
    family,
    // The inline-effort layout variant opts into these declared model choices; ordinary gallery
    // variants leave inlineEffort false and retain their standalone Effort row.
    efforts: ["low", "medium", "high"],
  }));

const families: QuickFamily[] = [
  {
    id: "claude",
    name: "Claude Code",
    mark: "claude",
    models: models("claude", ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]),
    more: models("claude", ["Opus 4.1", "Sonnet 4.5", "Haiku 4.5", "Opus 4", "Sonnet 4"]),
  },
  {
    id: "codex",
    name: "Codex",
    mark: "codex",
    models: models("codex", ["GPT-6.1-Sol", "GPT-6-Astra", "GPT-6-Luna"]),
    more: models("codex", ["Daybreak Blue", "GPT-5.5", "GPT-5.5 mini"]),
  },
  {
    id: "opencode",
    name: "OpenCode",
    mark: "opencode",
    models: models("opencode", [
      "opencode/Beam Free",
      "Big Pickle",
      "opencode/DeepSeek V4.1 Flash Free",
      "opencode/Flint 40B Free",
    ]),
    more: models("opencode", [
      "opencode/Qwen3 Coder 480B A35B Instruct Turbo Free (preview)",
      ...Array.from({ length: 40 }, (_, index) => `opencode/Sample Model ${index + 1}`),
    ]),
  },
  { id: "claude-sr", name: "Claude Code (sr)", mark: "claude", models: [], more: [], launch: true },
];

/// The rail Leo saw as nine tabs (2026-11-01: "we have too many harnesses because you didn't put
/// those things into accounts or whatever"): each Claude and OpenAI route is its own harness entry.
const routeFamilies: QuickFamily[] = [
  families[0]!,
  {
    id: "claude-sr2",
    name: "claude-sr2",
    mark: "claude",
    models: models("claude-sr2", ["Opus 5.5", "Sonnet 5.5"]),
    more: [],
  },
  families[1]!,
  { id: "codex-app-server", name: "Codex (app server)", mark: "codex", models: models("codex-app-server", ["GPT-6.1-Sol"]), more: [] },
  { id: "codex-sr2", name: "codex-sr2", mark: "codex", models: [], more: [], launch: true },
  { id: "cursor", name: "Cursor", mark: "cursor", models: models("cursor", ["Composer 2"]), more: [] },
  { id: "claude-work", name: "Claude Code (work)", mark: "claude", models: [], more: [], launch: true },
  families[2]!,
];

const extras: Pick<QuickMenu, "effort" | "fast"> = {
  effort: {
    levels: ["low", "medium", "high", "xhigh", "max"].map((id) => ({
      id,
      name: id[0]!.toUpperCase() + id.slice(1),
    })),
    current: "high",
    onPick: () => undefined,
  },
  fast: { checked: false, onChange: () => undefined },
};

const open: Play = async (ctx) => {
  await ctx.click({ selector: "button[data-menu='model']" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu") !== null);
};

export default componentEntry<Props>({
  id: "new-tab.quick-model-menu",
  title: "Model menu (New Tab)",
  area: "New Tab",
  height: 480,
  widths: { normal: 520 },
  covers: ["agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu"],
  // The pane's Tailwind too, as the app loads it (build-agent-pane-web.sh).
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./tailwind.css")]),
  load: () =>
    Promise.all([import("./QuickModelMenu"), import("./newTabComposer")]).then(
      ([{ QuickModelMenu }, { OnNewTab }]) =>
        function GalleryQuickModelMenu({
          tab,
          expand,
          chat,
          fast = false,
          many,
          anchorTop,
          anchorMiddle,
          placement,
          stress,
          inlineEffort = false,
          routeLayout,
          widthLook,
          routes,
        }: Props) {
          const [isOpen, setOpen] = useState(false);
          const trigger = useRef<HTMLButtonElement | null>(null);
          const [isFast, setFast] = useState(fast);
          const [selection, setSelection] = useState("");
          const [stars, setStars] = useState<ReadonlySet<string>>(() => new Set(["claude/Opus 5.5"]));
          const available = many
            ? [
                ...families,
                ...(stress
                  ? Array.from({ length: 36 }, (_, index) => `Harness ${index + 5}`)
                  : ["Cursor", "Gemini", "Copilot", "Amp", "Aider", "Goose"]
                ).map((name) => ({
                  id: name.toLowerCase(),
                  mark: name.toLowerCase(),
                  name,
                  models: models(name.toLowerCase(), [name + " model"]),
                  more: [],
                })),
              ]
            : routes
              ? routeFamilies
              : families;
          const list = tab ? [...available].sort((a, b) => (a.id === tab ? -1 : b.id === tab ? 1 : 0)) : available;
          return (
            <OnNewTab.Provider value={!chat}>
              <div
                style={{
                  padding: 16,
                  paddingTop: anchorMiddle ? 280 : chat && !anchorTop ? 400 : 16,
                }}
                data-expand={expand ? "" : undefined}
                data-selection={selection}
              >
                <QuickModelMenu
                  open={isOpen}
                  onOpenChange={setOpen}
                  trigger={trigger}
                  chip={{ "data-menu": "model", label: "Model", title: "Model" }}
                  menu={{
                    models: [],
                    current: "claude/Opus 5.5",
                    onModel: () => undefined,
                    ...extras,
                    ...(extras.effort
                      ? { effort: { ...extras.effort, onPick: (value: string) => setSelection(`effort:${value}`) } }
                      : {}),
                    inlineEffort,
                    ...(placement ? { harnessPlacement: placement } : {}),
                    routeLayout,
                    ...(widthLook ? { widthLook } : {}),
                    search: {
                      find: (query) =>
                        list
                          .flatMap((family) => [...family.models, ...family.more])
                          .filter((model) => model.name.toLowerCase().includes(query.toLowerCase())),
                      pick: (model) => setSelection(model.id),
                    },
                    account: {
                      sessionId: "gallery",
                      accounts: {
                        list: async () => ({
                          accounts: [
                            {
                              id: "subscription",
                              name: "Claude subscription",
                              kind: "direct-subscription",
                            },
                            { id: "api", name: "API key", kind: "direct-api-key" },
                            { id: "cmux", name: "Cmux", kind: "cmux-router" },
                          ],
                          active: "subscription",
                        }),
                        set: async () => undefined,
                      },
                    },
                    fast: { checked: isFast, onChange: setFast },
                    families: {
                      list,
                      current: tab ?? "claude",
                      onPick: (model) =>
                        setSelection(JSON.stringify({ family: model.family, model: model.id, effort: model.effort })),
                      onLaunch: (harness) => setSelection(harness),
                      onAddHarness: () => undefined,
                      stars: {
                        has: (model) => stars.has(model.id),
                        toggle: (model) =>
                          setStars((current) => {
                            const next = new Set(current);
                            if (!next.delete(model.id)) next.add(model.id);
                            return next;
                          }),
                      },
                    },
                  }}
                  onMore={() => undefined}
                >
                  Opus 5.5 High
                </QuickModelMenu>
              </div>
            </OnNewTab.Provider>
          );
        },
    ),
  variants: {
    "provider-submenu": {
      props: { chat: true, routeLayout: "submenu" },
      play: async (ctx) => {
        await open(ctx);
        await ctx.focus({ role: "menuitem", name: /^Account/ });
        await ctx.press("Enter");
      },
    },
    "provider-inline": { props: { chat: true, routeLayout: "inline" }, play: open },
    "provider-grouped": {
      props: { chat: true, routeLayout: "grouped" },
      play: async (ctx) => {
        await open(ctx);
        await ctx.focus({ role: "menuitem", name: /^Account/ });
        await ctx.press("Enter");
      },
    },
    "roomy-more-models": {
      height: 1000,
      props: { tab: "opencode" },
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-quick-disclosure" });
      },
    },
    "short-more-models": {
      height: 320,
      props: { tab: "opencode" },
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-quick-disclosure" });
      },
    },
    "newtab-midpoint": { props: { anchorMiddle: true }, play: open },
    "chat-flipped": { props: { chat: true, anchorTop: true }, play: open },
    "claude-many-harnesses": { props: { many: true }, play: open },
    "claude-many-harnesses-inline-effort": { props: { many: true, inlineEffort: true }, play: open },
    // As a chat's composer opens it: each row's effort dropdown on (ModelPicker passes inlineEffort).
    "in-chat": { props: { chat: true, inlineEffort: true }, play: open },
    combined: { props: { chat: true }, play: open },
    // The compact menu's widths (Leo 2026-11-01: "surely we can get more compact horizontally").
    "width-fit": { props: { chat: true, inlineEffort: true, widthLook: "fit" }, play: open },
    "width-stable": { props: { chat: true, inlineEffort: true, widthLook: "stable" }, play: open },
    "width-snug": { props: { chat: true, inlineEffort: true, widthLook: "snug" }, play: open },
    "width-wide": { props: { chat: true, inlineEffort: true, widthLook: "wide" }, play: open },
    // One tab per harness; its routes are its Account choices.
    "routes-one-tab": { props: { chat: true, inlineEffort: true, routes: true }, play: open },
    "routes-account": {
      props: { chat: true, inlineEffort: true, routes: true },
      play: async (ctx) => {
        await open(ctx);
        await ctx.focus({ role: "menuitem", name: /^Account/ });
        await ctx.press("Enter");
      },
    },
    "combined-fast": { props: { chat: true, fast: true }, play: open },
    "harness-symbols": { props: { placement: "symbols" }, play: open },
    "harness-symbols-many": { props: { placement: "symbols", many: true }, play: open },
    "harness-left": { props: { placement: "left" }, play: open },
    "harness-top": { props: { placement: "top" }, play: open },
    "harness-compact": { props: { placement: "compact" }, play: open },
    "harness-stress": { props: { many: true, stress: true }, play: open },
    claude: { props: {}, play: open },
    "claude-more-models": {
      props: {},
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-quick-disclosure" });
      },
    },
    opencode: { props: { tab: "opencode" }, play: open },
    "opencode-more-models": {
      props: { tab: "opencode" },
      play: async (ctx) => {
        await open(ctx);
        await ctx.click({ selector: ".acpmux-quick-disclosure" });
      },
    },
  },
});
