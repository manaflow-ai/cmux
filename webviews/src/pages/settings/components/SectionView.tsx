import { rowsInSection, sections } from "../schema";
import { text } from "../strings";
import { GroupList } from "./GroupList";
import { AccountsSection } from "./AccountsSection";
import { GhosttyDiagnostics } from "./GhosttyDiagnostics";
import { AdvancedInfo, Backdrops, TerminalInfo, ThemeLevels } from "./HostCards";
import { MachinesSection, RoomsSection } from "./HostSections";
import { SectionActions } from "./SectionActions";
import { PlaceholderSection } from "./PlaceholderSection";

export function SectionView({ section, focus }: { section: string; focus: string | null }) {
  const info = sections.find((item) => item.id === section)!;
  const rows = rowsInSection(section);
  return (
    <div className="section" data-section={section}>
      <h1 className="section-title">{text(info.title)}</h1>
      {section === "appearance" && <ThemeLevels />}
      {rows.length > 0 && <GroupList rows={rows} focus={focus} />}
      {section === "appearance" && <Backdrops />}
      {section === "terminal" && <TerminalInfo />}
      {section === "terminal" && <GhosttyDiagnostics />}
      {section === "rooms" && <RoomsSection />}
      {section === "machines" && <MachinesSection />}
      {section === "accounts" && <AccountsSection />}
      {section === "advanced" && <AdvancedInfo />}
      {section === "advanced" && <PlaceholderSection section={section} />}
      <SectionActions section={section} />
    </div>
  );
}
