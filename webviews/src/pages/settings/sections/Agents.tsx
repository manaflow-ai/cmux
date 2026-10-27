// Settings > Agents' cards, the agents section's chunk (lazySections.ts).
import { AgentHarnesses } from "../components/AgentHarnesses";
import { AgentIntegrations } from "../components/AgentIntegrations";
import { ComputerUseCard } from "../components/ComputerUseCard";
import { HarnessesCard } from "../components/HarnessesCard";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  harnesses: () => <HarnessesCard />,
  agentHarnesses: (focus) => <AgentHarnesses focus={focus} />,
  computerUse: () => <ComputerUseCard />,
  agentIntegrations: (focus) => <AgentIntegrations focus={focus} />,
};
