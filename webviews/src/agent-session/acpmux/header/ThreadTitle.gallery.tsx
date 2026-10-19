// l10n-allow-file: gallery fixtures (sample titles and folders), not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ThreadTitle } from "./ThreadTitle";

const editable = {
  folder: "/Users/you/src/atlas-web",
  title: "Fix the uploader",
  onRename: async () => undefined,
};

export default componentEntry<ComponentProps<typeof ThreadTitle>>({
  id: "agent-pane.thread-title",
  title: "Thread title",
  area: "Agent pane",
  pane: true,
  height: 120,
  covers: ["agent-session/acpmux/header/ThreadTitle.tsx#ThreadTitle"],
  load: () => import("./ThreadTitle").then((module) => module.ThreadTitle),
  variants: {
    project: { props: editable },
    "no-project": {
      props: { ...editable, folder: "/Users/you/Library/Application Support/cmux/agent-home/gallery" },
    },
    "no-folder": { props: { title: editable.title, onRename: editable.onRename } },
    "read-only": { props: { folder: editable.folder, title: editable.title } },
    "long-title": { props: { ...editable, title: "Check the uploader and retry interrupted transfers safely" } },
    editing: {
      props: editable,
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-thread-title__name" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thread-title__field"));
      },
    },
    renamed: {
      props: editable,
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-thread-title__name" });
        await ctx.type("Retry uploads");
        await ctx.press("Enter");
        await ctx.waitFor(
          () => ctx.document.querySelector(".acpmux-thread-title__name")?.textContent === "Retry uploads",
        );
      },
    },
  },
});
