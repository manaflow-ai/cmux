import { rowsInSection, sections } from "../schema";
import { text } from "../strings";
import { GroupList } from "./GroupList";
import { PlaceholderSection } from "./PlaceholderSection";

export function SectionView({ section, focus }: { section: string; focus: string | null }) {
  const info = sections.find((item) => item.id === section)!;
  const rows = rowsInSection(section);
  return (
    <div className="section" data-section={section}>
      <h1 className="section-title">{text(info.title)}</h1>
      {rows.length > 0 && <GroupList rows={rows} focus={focus} />}
      {(rows.length === 0 || section === "advanced") && (
        <PlaceholderSection section={section} openInWindow={rows.length === 0} />
      )}
    </div>
  );
}
