// Settings > Server's cards, the server section's chunk (lazySections.ts).
import { ServerCard } from "../components/ServerCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  server: () => <ServerCard />,
};
