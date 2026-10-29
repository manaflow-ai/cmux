// Settings > Accounts' cards, the accounts section's chunk (lazySections.ts).
import { AccountsSection } from "../components/AccountsSection";
import { CloudEnvironmentsCard } from "../components/CloudEnvironmentsCard";
import { MachinesSection } from "../components/HostSections";
import type { SectionModule } from "../lazySections";
import { sections } from "../schema";
import { text } from "../strings";

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

export const cards: SectionModule["cards"] = {
  accounts: () => <AccountsSection />,
  machines: () => <MachinesSection title={machinesTitle()} />,
  cloudEnvironments: () => <CloudEnvironmentsCard />,
};
