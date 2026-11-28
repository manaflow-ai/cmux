// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../gallery/format";
import type { GhosttyTheme } from "../theme/ghosttyTheme";
import { ThemeBall } from "./ThemeBall";

/** Famous themes, dark then light, so families (Catppuccin, Rose Pine, GitHub) sit side by side. */
const FAMOUS = [
  "Catppuccin Mocha",
  "JetBrains Darcula",
  "Rose Pine",
  "Rose Pine Moon",
  "Dark Modern",
  "GitHub Dark Default",
  "GitHub Dark High Contrast",
  "Dracula",
  "Nord",
  "Gruvbox Dark",
  "TokyoNight",
  "Atom One Dark",
  "Catppuccin Latte",
  "Rose Pine Dawn",
  "GitHub Light Default",
  "TokyoNight Day",
  "Atom One Light",
  "Apple System Colors Light",
];

type Props = { size?: number };

function sheet(themes: readonly GhosttyTheme[]) {
  const byName = new Map(themes.map((theme) => [theme.name, theme]));
  return function ThemeBallGallery({ size = 20 }: Props) {
    return (
      <div
        style={{
          display: "grid",
          gridTemplateColumns: `repeat(auto-fill, minmax(${size + 170}px, 1fr))`,
          gap: 10,
          padding: 16,
        }}
      >
        {FAMOUS.map((name) => (
          <div key={name} style={{ display: "flex", alignItems: "center", gap: 10, minHeight: 28 }}>
            <ThemeBall name={name} colors={byName.get(name)} size={size} />
            <span style={{ fontSize: "var(--text-body)" }}>{name}</span>
          </div>
        ))}
      </div>
    );
  };
}

export default componentEntry<Props>({
  id: "ui.theme-ball",
  title: "Theme ball",
  area: "Settings",
  covers: ["ui/ThemeBall.tsx#ThemeBall"],
  load: async () => sheet((await import("virtual:cmux-gallery/themes")).default),
  variants: {
    picker: { note: "Famous themes at the picker's 20px size, dark then light.", props: { size: 20 } },
    large: { note: "The same balls at 48px: every mark is a crisp circle.", props: { size: 48 } },
  },
});
