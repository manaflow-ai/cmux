// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { componentEntry } from "../format";
import type { PropagationMatrixProps } from "./PropagationMatrix";

export default componentEntry<PropagationMatrixProps>({
  id: "theme.propagation",
  title: "Theme propagation",
  area: "Settings",
  height: 900,
  covers: ["gallery/theme/PropagationMatrix.tsx", "gallery/theme/propagation.ts", "gallery/theme/overlays.ts"],
  load: async () => {
    const [{ propagationMatrix }, themes] = await Promise.all([
      import("./PropagationMatrix"),
      import("virtual:cmux-gallery/themes"),
    ]);
    return propagationMatrix(themes.default);
  },
  styles: () => import("./propagationMatrix.css"),
  variants: {
    matrix: {
      props: { show: "matrix" },
      note: "Every appearance knob set live (no reload) and every web surface read back; then the native-only knobs and their proof.",
    },
    contrast: {
      props: { show: "contrast" },
      note: "Text over the tooltip and card glass and over the window's wallpaper tint, on the worst backdrop (pure black or white).",
    },
  },
});
