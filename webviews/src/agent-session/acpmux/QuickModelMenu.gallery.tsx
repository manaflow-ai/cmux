// l10n-allow-file: gallery fixtures (sample models), not shipped UI.
// The compact model menu as the New Tab page draws it (newTabComposer.ts): it opens down, has no
// heading and no key hints, and More models shows a tab's other models in place. The OpenCode tab
// has no Effort, Account or Fast mode rows and a long More models list.
import React, { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { QuickFamily, QuickMenu } from "./QuickModelMenu";

type Props = { tab?: string; expand?: boolean };

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
  { id: "unii", name: "Unii", models: [], more: [], note: "Signed out" },
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
        function GalleryQuickModelMenu({ tab, expand }: Props) {
          const [isOpen, setOpen] = useState(false);
          const trigger = useRef<HTMLButtonElement | null>(null);
          const list = tab ? [...families].sort((a, b) => (a.id === tab ? -1 : b.id === tab ? 1 : 0)) : families;
          return (
            <OnNewTab.Provider value={true}>
              <div style={{ padding: 16 }} data-expand={expand ? "" : undefined}>
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
                    families: {
                      list,
                      current: tab ?? "claude",
                      onPick: () => undefined,
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
