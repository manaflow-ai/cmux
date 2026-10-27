// Settings > Browser's cards, the browser section's chunk (lazySections.ts).
import { BrowserProfiles } from "../components/HostSections";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  browserProfiles: () => <BrowserProfiles />,
};
