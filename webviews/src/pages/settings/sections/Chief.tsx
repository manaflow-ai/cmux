// Settings > Chief's cards, the chief section's chunk (lazySections.ts). The search results draw the
// Chief Pet card too, for the rows it owns.
import { ChiefPetCard } from "../components/ChiefPetCard";
import { ChiefsCard } from "../components/ChiefsCard";
import { VoiceInputCard } from "../components/VoiceInputCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  chiefs: () => <ChiefsCard />,
  chiefPet: (focus) => <ChiefPetCard focus={focus} />,
  voiceInput: () => <VoiceInputCard />,
};

export const searchCards: SectionModule["searchCards"] = {
  chiefPet: ({ query, visibleRows }) => <ChiefPetCard query={query} visibleRows={visibleRows} />,
};
