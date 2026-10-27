// Settings > Appearance's cards, the appearance section's chunk (lazySections.ts).
import { DensityCard } from "../components/DensityCard";
import { Backdrops } from "../components/HostCards";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  backdrops: (focus, workspace) => <Backdrops focus={focus} workspace={workspace} />,
  density: () => <DensityCard />,
};
