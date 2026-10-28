// Settings > Experimental's cards, the experimental section's chunk (lazySections.ts).
import { FeatureFlagsCard } from "../components/FeatureFlagsCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  featureFlags: () => <FeatureFlagsCard />,
};
