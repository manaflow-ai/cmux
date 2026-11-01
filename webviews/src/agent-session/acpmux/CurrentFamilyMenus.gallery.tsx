// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { BUNDLED_MODEL_CATALOG } from "./modelCatalogData";

type Props = { harness: "claude" | "codex"; surface: "composer" | "retry" };
const open: Play = async (ctx) => {
  const retry = ctx.document.querySelector(".cv-turn-retry-menu");
  await ctx.click({ selector: retry ? ".cv-turn-retry-menu" : ".acpmux-model .acpmux-picker-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.current-family-menus",
  title: "Current model families across menus",
  area: "Agent pane",
  pane: true,
  height: 480,
  widths: { narrow: 320, normal: 440, wide: 560 },
  covers: [
    "agent-session/acpmux/relevantModels.ts",
    "agent-session/acpmux/conversation/retryModelSections.ts",
    "agent-session/acpmux/topModels/index.ts",
  ],
  load: async () => {
    const { ModelPicker } = await import("./ModelPicker");
    const { RetryModelMenu } = await import("./conversation/RetryModelMenu");
    return function CurrentFamilyMenus({ harness: id, surface }: Props) {
      const harness = BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === id)!;
      const models = harness.models.map((model) => ({ ...model, name: model.shortName || model.name }));
      const current = harness.defaultModel;
      return (
        <div style={{ padding: 24 }}>
          {surface === "retry" ? (
            <RetryModelMenu retryWith={{ models, current, harness: harness.name, retry: () => {} }} onPick={() => {}} />
          ) : (
            <ModelPicker
              catalog={[{ id, name: harness.name, models }]}
              harness={id}
              harnessFixed
              model={current}
              label={models.find((model) => model.id === current)?.name ?? harness.name}
              efforts={[]}
              recents={[]}
              quick={{}}
              onLand={() => {}}
              onEffort={() => {}}
            />
          )}
        </div>
      );
    };
  },
  styles: () =>
    Promise.all([import("./styles.css"), import("./conversation/conversation.css"), import("./modelPicker.css")]),
  variants: {
    "claude-composer": { props: { harness: "claude", surface: "composer" }, play: open },
    "claude-retry": { props: { harness: "claude", surface: "retry" }, play: open },
    "codex-composer": { props: { harness: "codex", surface: "composer" }, play: open },
    "codex-retry": { props: { harness: "codex", surface: "retry" }, play: open },
  },
});
