// l10n-allow-file: gallery fixtures, not shipped UI.
import React, { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { QuickMenu } from "./QuickModelMenu";

type Props = {
  look?: QuickMenu["effortLook"];
  chat?: boolean;
  placement?: QuickMenu["harnessPlacement"];
  /// Codex's eight models, each with up to six levels, as Leo's 2026-10-29 screenshot showed them.
  codex?: boolean;
};

const CODEX_LEVELS = ["low", "medium", "high", "xhigh", "max", "ultra"];
const LEVEL_NAMES: Record<string, string> = {
  low: "Low",
  medium: "Medium",
  high: "High",
  xhigh: "Extra High",
  max: "Max",
  ultra: "Ultra",
};
const CODEX_MODELS = [
  ["gpt-6.1-sol", "GPT-6.1 Sol", 6],
  ["gpt-6-astra", "GPT-6 Astra", 6],
  ["gpt-6.1-terra", "GPT-6.1 Terra", 6],
  ["gpt-6-sol", "GPT-6 Sol", 6],
  ["gpt-6-luna", "GPT-6 Luna", 5],
  ["gpt-5.6-sol", "GPT-5.6 Sol", 6],
  ["gpt-5.6-terra", "GPT-5.6 Terra", 6],
  ["gpt-5.6-luna", "GPT-5.6 Luna", 5],
  ["daybreak-blue", "Daybreak Blue", 6],
] as const;

export default componentEntry<Props>({
  id: "agent-pane.inline-model-effort",
  title: "Model and effort in one click",
  area: "Agent pane",
  height: 540,
  widths: { normal: 680, narrow: 380 },
  covers: ["agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css")]),
  load: () =>
    Promise.all([import("./QuickModelMenu"), import("./newTabComposer")]).then(
      ([{ QuickModelMenu }, { OnNewTab }]) =>
        function InlineModelEffort({ look = "joined", chat = false, placement = "left", codex = false }: Props) {
          const trigger = useRef<HTMLButtonElement | null>(null);
          const [open, setOpen] = useState(false);
          const [model, setModel] = useState(codex ? "gpt-6.1-sol" : "opus");
          const [effort, setEffort] = useState(codex ? "xhigh" : "high");
          const levels = codex ? CODEX_LEVELS : ["low", "medium", "high", "max"];
          const models = codex
            ? CODEX_MODELS.map(([id, name, count]) => ({
                id,
                name,
                family: "codex",
                efforts: CODEX_LEVELS.slice(0, count),
              }))
            : [
            {
              id: "opus",
              name: "Opus 5.5",
              family: "claude",
              efforts: ["low", "medium", "high", "max"],
            },
            {
              id: "sonnet",
              name: "Sonnet 5.5",
              family: "claude",
              efforts: ["low", "medium", "high"],
            },
                { id: "haiku", name: "Haiku 5.5", family: "claude", efforts: [] },
              ];
          return (
            <OnNewTab.Provider value={!chat}>
              <div style={{ padding: 24, paddingTop: chat ? 460 : 24 }} data-model={model} data-effort={effort}>
                <QuickModelMenu
                  open={open}
                  onOpenChange={setOpen}
                  trigger={trigger}
                  chip={{ "data-menu": "model", label: "Model", title: "Model" }}
                  onMore={() => undefined}
                  menu={{
                    models,
                    current: model,
                    onModel: setModel,
                    effortLook: look,
                    inlineEffort: true,
                    harnessPlacement: placement,
                    effort: {
                      current: effort,
                      levels: levels.map((id) => ({ id, name: codex ? LEVEL_NAMES[id]! : id })),
                      onPick: setEffort,
                    },
                    families: {
                      current: codex ? "codex" : "claude",
                      list: codex
                        ? [
                            { id: "claude", name: "Claude Code", mark: "claude", models: [], more: [] },
                            { id: "codex", name: "Codex", mark: "codex", models, more: [] },
                            { id: "opencode", name: "OpenCode", models: [], more: [] },
                          ]
                        : [{ id: "claude", name: "Claude Code", mark: "claude", models, more: [] }],
                      onPick: (picked) => {
                        setModel(picked.id);
                        if (picked.effort) setEffort(picked.effort);
                      },
                    },
                  }}
                >
                  {models.find((row) => row.id === model)?.name} {effort}
                </QuickModelMenu>
              </div>
            </OnNewTab.Provider>
          );
        },
    ),
  variants: {
    joined: {
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
    spaced: {
      props: { look: "spaced" },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
    underline: {
      props: { look: "underline" },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
    chat: {
      props: { chat: true },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
    // Leo 2026-10-29's screenshot: Codex's eight models. One row each; only the running row (and a
    // hovered one) shows its levels, on its own line.
    codex: {
      props: { codex: true, chat: true },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
    "codex-hover": {
      props: { codex: true, chat: true },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
        await ctx.hover({ role: "menuitemradio", name: /^GPT-6 Astra/ });
      },
    },
    compact: {
      props: { placement: "compact" },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
      },
    },
  },
});
