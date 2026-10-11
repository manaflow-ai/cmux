// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { VariantPickDemoProps } from "./VariantPickDemo";

export default componentEntry<VariantPickDemoProps>({
  id: "ui.variant-pick",
  title: "Variant pick",
  area: "Pages",
  covers: [
    "ui/variant-pick/VariantPick.tsx",
    "ui/variant-pick/RecordedVariantPick.tsx",
    "ui/variant-pick/VariantPickDemo.tsx",
    "agent-session/acpmux/conversation/RenderVariantsPick.tsx",
  ],
  pick: { beadId: "cx-czd", recommendedId: "a" },
  load: () => import("./VariantPickDemo").then((module) => module.VariantPickDemo),
  variants: {
    a: { note: "Gallery choices with previews", props: { surface: "gallery" } },
    b: { note: "In-thread choices using the same control", props: { surface: "thread" } },
    c: {
      note: "More than three options, keyboard selection",
      props: { surface: "many" },
      play: async (ctx) => {
        await ctx.focus({ selector: ".variant-pick-button" });
        await ctx.press("ArrowRight");
        await ctx.press("Enter");
      },
    },
  },
});
