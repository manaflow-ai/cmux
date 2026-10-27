// Settings > Advanced's cards, the advanced section's chunk (lazySections.ts).
import { AdvancedInfo } from "../components/AdvancedInfo";
import { PlaceholderSection } from "../components/PlaceholderSection";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  advancedInfo: () => <AdvancedInfo />,
  advancedActions: () => <PlaceholderSection section="advanced" />,
};
