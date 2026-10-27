// Settings > Updates's cards, the updates section's chunk (lazySections.ts).
import { ChannelsCard } from "../components/ChannelsCard";
import { WebUpdatesCard } from "../components/WebUpdatesCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  webUpdates: () => <WebUpdatesCard />,
  channels: () => <ChannelsCard />,
};
