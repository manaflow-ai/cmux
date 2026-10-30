// l10n-allow-file: gallery fixtures, not shipped UI.
import React, { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { QuickMenu } from "./QuickModelMenu";

type Props = {
  /// Where the one effort slider sits: `hover` (shipped), `running` or `list`.
  slider?: QuickMenu["effortSlider"];
  /// The running model's level, for the every-level entries.
  level?: string;
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

const open: Play = async (ctx) => {
  await ctx.click({ selector: "button[data-menu='model']" });
};
const hoverAstra: Play = async (ctx) => {
  await open(ctx);
  await ctx.hover({ role: "menuitemradio", name: /^GPT-6 Astra/ });
};

export default componentEntry<Props>({
  id: "agent-pane.inline-model-effort",
  title: "Model and effort in one click",
  area: "Agent pane",
  height: 540,
  widths: { normal: 680, narrow: 380 },
  covers: ["agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu"],
  styles: () => Promise.all([import("./styles.css"), import("./modelPicker.css"), import("./composerControls.css")]),
  load: () =>
    Promise.all([import("./QuickModelMenu"), import("./newTabComposer")]).then(
      ([{ QuickModelMenu }, { OnNewTab }]) =>
        function InlineModelEffort({
          slider = "hover",
          level,
          chat = false,
          placement = "left",
          codex = false,
        }: Props) {
          const trigger = useRef<HTMLButtonElement | null>(null);
          const [open, setOpen] = useState(false);
          const [model, setModel] = useState(codex ? "gpt-6.1-sol" : "opus");
          const [effort, setEffort] = useState(level ?? (codex ? "xhigh" : "high"));
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
                    effortSlider: slider,
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
    // The shipped look: one slider, on the hovered row or else the running row.
    hover: { props: {}, play: open },
    running: { props: { slider: "running" }, play: open },
    list: { props: { slider: "list" }, play: open },
    chat: { props: { chat: true }, play: open },
    // Leo 2026-10-29's screenshot: Codex's nine models, one line each, one slider.
    codex: { props: { codex: true }, play: open },
    "codex-chat": { props: { codex: true, chat: true }, play: hoverAstra },
    "codex-hover": { props: { codex: true }, play: hoverAstra },
    "codex-running": { props: { codex: true, slider: "running" }, play: hoverAstra },
    "codex-list": { props: { codex: true, slider: "list" }, play: open },
    // The thumb at every level, ends included (Leo 2026-10-29: "the circle center wasn't on the
    // selection scenter"): quick-model-menu-layout.test.ts measures each one.
    ...Object.fromEntries(CODEX_LEVELS.map((id) => [`level-${id}`, { props: { codex: true, level: id }, play: open }])),
    // Harness tabs across the top (Debug Settings harnessPlacement=top; Leo 2026-10-29: "didnt we
    // already have a pretty good thign going on with the harnesses at the top?"), with the slider.
    "codex-top": { props: { codex: true, placement: "top" }, play: open },
    "codex-top-hover": { props: { codex: true, placement: "top" }, play: hoverAstra },
    "codex-top-running": { props: { codex: true, placement: "top", slider: "running" }, play: hoverAstra },
    "codex-top-list": { props: { codex: true, placement: "top", slider: "list" }, play: open },
    "codex-compact": { props: { codex: true, placement: "compact" }, play: hoverAstra },
    compact: { props: { placement: "compact" }, play: open },
  },
});
