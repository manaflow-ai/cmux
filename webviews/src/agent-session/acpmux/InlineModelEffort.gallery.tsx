// l10n-allow-file: gallery fixtures, not shipped UI.
import React, { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { QuickMenu } from "./QuickModelMenu";

type Props = { look?: QuickMenu["effortLook"]; chat?: boolean; placement?: QuickMenu["harnessPlacement"] };

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
        function InlineModelEffort({ look = "list", chat = false, placement = "left" }: Props) {
          const trigger = useRef<HTMLButtonElement | null>(null);
          const [open, setOpen] = useState(false);
          const [model, setModel] = useState("opus");
          const [effort, setEffort] = useState("high");
          const models = [
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
                      // Medium is the model's own pick: the list names it Recommended.
                      levels: ["low", "medium", "high", "max"].map((id) => ({
                        id,
                        name: id,
                        ...(id === "medium" ? { recommended: true } : {}),
                      })),
                      onPick: setEffort,
                    },
                    families: {
                      current: "claude",
                      list: [{ id: "claude", name: "Claude Code", mark: "claude", models, more: [] }],
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
  // A model's effort as a vertical side dropdown beside it (Leo 2026-10-30: "we dont like
  // horizontal text for effort. just make it vertical. hell, why not do a vertical slider?"):
  // `list` (the default, the recommended level named), `plain`, `slider`; `list-open` hovers the
  // running model so its dropdown shows.
  variants: {
    list: {
      props: {},
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
        await ctx.hover({ selector: ".acpmux-quick-model-effort[data-running] > .acpmux-quick-item" });
      },
    },
    plain: {
      props: { look: "plain" },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
        await ctx.hover({ selector: ".acpmux-quick-model-effort[data-running] > .acpmux-quick-item" });
      },
    },
    slider: {
      props: { look: "slider" },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
        await ctx.hover({ selector: ".acpmux-quick-model-effort[data-running] > .acpmux-quick-item" });
      },
    },
    chat: {
      props: { chat: true },
      play: async (ctx) => {
        await ctx.click({ selector: "button[data-menu='model']" });
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
