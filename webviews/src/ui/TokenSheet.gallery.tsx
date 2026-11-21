// l10n-allow-file: gallery labels are fixture content, not shipped UI.
import { componentEntry } from "../gallery/format";
import { TokenSheet, type TokenSheetProps } from "./TokenSheet";

export default componentEntry<TokenSheetProps>({
  id: "ui.token-sheet",
  title: "Design tokens",
  area: "UI primitives",
  height: 2400,
  covers: ["ui/TokenSheet.tsx", "ui/designTokens.generated.ts"],
  load: async () => TokenSheet,
  styles: () => Promise.all([import("./ui.css"), import("./controls.gallery.css")]),
  variants: {
    all: { props: {}, note: "Every token of schemas/design-scale, type-scale and motion-scale." },
    colors: { props: { only: "colors" }, note: "Colour roles: the active theme, light and dark." },
  },
});
