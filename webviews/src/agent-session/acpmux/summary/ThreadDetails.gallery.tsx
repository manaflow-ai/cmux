// l10n-allow-file: gallery fixtures (sample machines and apps), not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ThreadDetails } from "./ThreadDetails";

const props = {
  folder: "/Users/you/src/atlas-web",
  machine: "Studio",
  openIn: async () => [
    { id: "editor", name: "Editor" },
    { id: "finder", name: "File browser" },
  ],
};

export default componentEntry<ComponentProps<typeof ThreadDetails>>({
  id: "agent-pane.thread-details",
  title: "Thread details",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 240, normal: 320, wide: 440 },
  covers: ["agent-session/acpmux/summary/ThreadDetails.tsx#ThreadDetails"],
  load: () => import("./ThreadDetails").then((module) => module.ThreadDetails),
  variants: {
    local: { props },
    "machine-only": { props: { folder: props.folder, machine: props.machine } },
    "single-app": { props: { ...props, openIn: async () => [{ id: "editor", name: "Editor" }] } },
    "no-apps": { props: { ...props, openIn: async () => [] } },
    "app-menu": {
      props,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-details__more"));
        await ctx.click({ selector: ".acpmux-thread-details__more" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
      },
    },
  },
});
