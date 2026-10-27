// Settings > Terminal's cards, the terminal section's chunk (lazySections.ts).
import { GhosttyDiagnostics } from "../components/GhosttyDiagnostics";
import { TerminalInfo } from "../components/TerminalInfo";
import type { SectionModule } from "../lazySections";

export const cards: SectionModule["cards"] = {
  terminalInfo: () => <TerminalInfo />,
  ghosttyDiagnostics: () => <GhosttyDiagnostics />,
};
