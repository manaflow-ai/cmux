// Settings > Devices's cards, the devices section's chunk (lazySections.ts).
import { DevicesCard } from "../components/DevicesCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  devices: () => <DevicesCard />,
};
