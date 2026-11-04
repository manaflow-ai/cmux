// l10n-allow-file: gallery metadata and synthetic model catalog.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { RacePanel } from "./RacePanel";
import { fixtureRaceClient, raceFixture } from "./fixtures";

const props: ComponentProps<typeof RacePanel> = {
  parent: raceFixture.parent,
  catalog: [
    {
      id: "codex",
      name: "Codex",
      models: [
        { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" },
        { id: "gpt-6-astra", name: "GPT-6 Astra" },
      ],
    },
    { id: "claude", name: "Claude", models: [{ id: "opus", name: "Opus" }] },
  ],
  client: fixtureRaceClient(raceFixture),
  onClose: () => undefined,
  onOpenSession: () => undefined,
};
const start: Play = async (ctx) => {
  await ctx.type("Improve the empty state", { role: "textbox", name: "Task" });
  await ctx.click({ role: "checkbox", name: "Codex · GPT-6.1 Sol" });
  await ctx.click({ role: "checkbox", name: "Claude · Opus" });
  await ctx.focus({ role: "combobox", name: "Reviewer" });
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.click({ role: "button", name: "Start race" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-winner="true"]'));
};
export default componentEntry<ComponentProps<typeof RacePanel>>({
  id: "agent-pane.model-race-launch",
  title: "Model race launch",
  area: "Agent pane",
  pane: true,
  height: 650,
  widths: { narrow: 420, normal: 900, wide: 1200 },
  covers: ["agent-session/acpmux/races/RacePanel.tsx#RacePanel"],
  styles: () => import("./styles.css"),
  load: async () => (await import("./RacePanel")).RacePanel,
  variants: {
    launch: { props, note: "Task and catalog-backed model/reviewer choices; one race launch form." },
    result: {
      props,
      play: start,
      note: "Submitting the real form opens the returned fixture race and reads the reviewer’s selected candidate.",
    },
  },
});
