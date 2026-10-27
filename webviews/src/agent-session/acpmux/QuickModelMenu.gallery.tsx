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
  placement?: "left" | "top" | "compact";
  stress?: boolean;
  anchorTop?: boolean;
  anchorMiddle?: boolean;
};

const models = (family: string, names: string[]) => names.map((name) => ({ id: `${family}/${name}`, name, family }));

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

const extras: Pick<QuickMenu, "effort" | "fast"> = {
  effort: {
    levels: ["low", "medium", "high", "xhigh", "max"].map((id) => ({ id, name: id[0]!.toUpperCase() + id.slice(1) })),
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
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
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
          placement = "left",
          stress,
        }: Props) {
          const [isOpen, setOpen] = useState(false);
          const trigger = useRef<HTMLButtonElement | null>(null);
          const [isFast, setFast] = useState(fast);
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
            : families;
          const list = tab ? [...available].sort((a, b) => (a.id === tab ? -1 : b.id === tab ? 1 : 0)) : available;
          return (
            <OnNewTab.Provider value={!chat}>
              <div
                style={{ padding: 16, paddingTop: anchorMiddle ? 280 : chat && !anchorTop ? 400 : 16 }}
                data-expand={expand ? "" : undefined}
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
                    harnessPlacement: placement,
                    account: {
                      sessionId: "gallery",
                      accounts: {
                        list: async () => ({
                          accounts: [
                            { id: "subscription", name: "Claude subscription", kind: "direct-subscription" },
                            { id: "api", name: "API key", kind: "direct-api-key" },
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
                      onPick: () => undefined,
                      onLaunch: () => undefined,
                      onAddHarness: () => undefined,
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
    "newtab-midpoint": { props: { anchorMiddle: true }, play: open },
    "chat-flipped": { props: { chat: true, anchorTop: true }, play: open },
    "claude-many-harnesses": { props: { many: true }, play: open },
    combined: { props: { chat: true }, play: open },
    "combined-fast": { props: { chat: true, fast: true }, play: open },
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
