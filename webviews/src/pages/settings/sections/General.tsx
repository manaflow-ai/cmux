// Settings > General's cards, the general section's chunk (lazySections.ts).
import { SpacesSection } from "../components/HostSections";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  spaces: () => <SpacesSection />,
};
