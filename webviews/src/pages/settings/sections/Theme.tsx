// Settings > Theme's cards, the theme section's chunk (lazySections.ts).
import { ThemeStudio } from "../components/ThemeStudio";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  themeStudio: (focus) => <ThemeStudio focus={focus} />,
};
