// l10n-allow-file: gallery fixture labels, not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { SurfaceLauncher } from "./SurfaceLauncher";

export default componentEntry<ComponentProps<typeof SurfaceLauncher>>({
  id: "agent-pane.surface-launcher",
  title: "Side column launcher",
  area: "Agent pane",
  pane: true,
  height: 420,
  widths: { narrow: 240, normal: 360, wide: 520 },
  covers: ["agent-session/acpmux/newtab/SurfaceLauncher.tsx#SurfaceLauncher"],
  load: () => import("./SurfaceLauncher").then((module) => module.SurfaceLauncher),
  variants: {
    tiles: { props: { onPick: () => undefined } },
    "keyboard-focus": {
      props: { onPick: () => undefined },
      play: async (ctx) => {
        await ctx.focus({ selector: '[data-surface="terminal"]' });
        await ctx.press("Tab");
      },
    },
  },
});
