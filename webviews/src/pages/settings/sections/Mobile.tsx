// Settings > Mobile's cards, the mobile section's chunk (lazySections.ts).
import { MobileCard } from "../components/MobileCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  mobile: () => <MobileCard />,
};
