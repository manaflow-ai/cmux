import { rowsInSection, sections } from "../schema";
import { text } from "../strings";
import { GroupList } from "./GroupList";
import { MachinesSection, RoomsSection } from "./HostSections";
import { PlaceholderSection } from "./PlaceholderSection";

/** Sections the page draws from the host lists instead of schema rows. */
const hostSections = new Set(["rooms", "machines"]);

export function SectionView({ section, focus }: { section: string; focus: string | null }) {
  const info = sections.find((item) => item.id === section)!;
  const rows = rowsInSection(section);
  return (
    <div className="section" data-section={section}>
      <h1 className="section-title">{text(info.title)}</h1>
      {rows.length > 0 && <GroupList rows={rows} focus={focus} />}
      {section === "rooms" && <RoomsSection />}
      {section === "machines" && <MachinesSection />}
      {((rows.length === 0 && !hostSections.has(section)) || section === "advanced") && (
        <PlaceholderSection section={section} openInWindow={rows.length === 0} />
      )}
    </div>
  );
}
