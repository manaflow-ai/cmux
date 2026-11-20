// l10n-allow-file: gallery fixture labels and synthetic prices, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { UnitCostProps } from "./UnitCostScreen";
const estimate: Play = async (ctx) => {
  await ctx.type("900", ".ucs label:nth-of-type(1) input");
  await ctx.type("2", ".ucs label:nth-of-type(2) input");
  await ctx.type("50", ".ucs label:nth-of-type(3) input");
  await ctx.click(".ucs button");
  await ctx.waitFor(
    () =>
      !ctx.document.querySelector("button")?.hasAttribute("disabled") &&
      !!ctx.document.querySelector("output")?.textContent,
  );
};
export default componentEntry<UnitCostProps>({
  id: "agent-pane.unit-cost",
  title: "Unit cost",
  area: "Agent pane",
  experimental: true,
  covers: ["agent-session/acpmux/unitCost/UnitCostScreen.tsx#UnitCostScreen"],
  styles: () => Promise.all([import("../styles.css"), import("./unitCost.css")]),
  load: () => import("./UnitCostScreen").then((module) => module.UnitCostScreen),
  widths: { narrow: 380, normal: 720, wide: 960 },
  height: 360,
  anchors: [{ selector: ".ucs" }],
  variants: {
    empty: { note: "No guessed prices: every assumption starts blank.", props: { load: async () => ({ costUsd: 1 }) } },
    estimate: {
      note: "900 seconds at 2 USD/hour and 50% busy: the daemon's synthetic reply is 1 USD.",
      props: { load: async () => ({ costUsd: 1 }) },
      play: estimate,
    },
    older: {
      note: "An older daemon asks the person to update instead of showing zero.",
      props: {
        load: async () => {
          throw { code: -32601 };
        },
      },
      play: estimate,
    },
    failed: {
      note: "Invalid input or connection failure can be corrected and retried.",
      props: {
        load: async () => {
          throw { code: -32602 };
        },
      },
      play: estimate,
    },
  },
});
