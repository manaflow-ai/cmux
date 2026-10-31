// l10n-allow-file: gallery fixtures, not shipped UI.
// The Theme studio's editable swatches (cx-wqn5) over the mock provider's themes: as shipped, with
// one edited token, and locked while no named theme is chosen or the key is managed.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { withEdits } from "../../../theme/themeEdits";
import table from "../generated/strings.json";
import { mockThemeColors } from "../mockThemes";
import { installCatalog, setLocale } from "../strings";
import { ThemeTokens } from "./ThemeTokens";

type Props = { edits?: Record<string, string> | null; editable?: boolean };

const base = mockThemeColors[0]!;

function ThemeTokensGallery({ edits = null, editable = true }: Props) {
  const [current, setCurrent] = useState(edits);
  return (
    <div style={{ padding: 16 }}>
      <ThemeTokens
        theme={withEdits(base, current)}
        base={base}
        edits={current}
        others={mockThemeColors}
        editable={editable}
        onPreview={() => {}}
        onCommit={(token, color) => {
          const key = `${base.name}/${token}`;
          const next: Record<string, string> = { ...current };
          if (color === null) delete next[key];
          else next[key] = color;
          setCurrent(next);
        }}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.settings.theme-tokens",
  title: "Theme tokens",
  area: "Settings",
  covers: ["pages/settings/components/ThemeTokens.tsx#ThemeTokens"],
  load: async () => {
    installCatalog(table);
    setLocale(navigator.language);
    return ThemeTokensGallery;
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../page.css");
  },
  height: 220,
  variants: {
    default: {
      note: "The theme as it ships: every swatch opens its tuner.",
      props: {},
    },
    edited: {
      note: "One edited token (cursor) carries the edited mark; Reset in its tuner removes it.",
      props: { edits: { [`${base.name}/cursor`]: "#ff9f0a" } },
    },
    locked: {
      note: "No named theme chosen, or appearance.themeEdits managed: the swatches show but do not open.",
      props: { editable: false },
    },
  },
});
