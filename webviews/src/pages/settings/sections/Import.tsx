// Settings > Import's cards, the import section's chunk (lazySections.ts).
import { ImportSuggestionsCard } from "../components/ImportSuggestionsCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  importSuggestions: () => <ImportSuggestionsCard />,
};
