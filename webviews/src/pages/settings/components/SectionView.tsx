import type { ReactNode } from "react";
import { categoryById, type CategoryCard } from "../categories";
import { sections } from "../schema";
import { text } from "../strings";
import { AccountsSection } from "./AccountsSection";
import { ComputerUseCard } from "./ComputerUseCard";
import { GhosttyDiagnostics } from "./GhosttyDiagnostics";
import { GroupList } from "./GroupList";
import { HarnessesCard } from "./HarnessesCard";
import { AdvancedInfo, Backdrops, TerminalInfo } from "./HostCards";
import { BrowserProfiles, MachinesSection, SpacesSection } from "./HostSections";
import { PlaceholderSection } from "./PlaceholderSection";
import { SectionActions } from "./SectionActions";
import { APP_THEME_KEY, THEME_KEY, ThemeStudio } from "./ThemeStudio";

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

const CARDS: Record<CategoryCard, () => ReactNode> = {
  themeStudio: () => <ThemeStudio />,
  terminalInfo: () => <TerminalInfo />,
  ghosttyDiagnostics: () => <GhosttyDiagnostics />,
  computerUse: () => <ComputerUseCard />,
  harnesses: () => <HarnessesCard />,
  spaces: () => <SpacesSection />,
  browserProfiles: () => <BrowserProfiles />,
  machines: () => <MachinesSection title={machinesTitle()} />,
  accounts: () => <AccountsSection />,
  advancedInfo: () => <AdvancedInfo />,
  advancedActions: () => <PlaceholderSection section="advanced" />,
  backdrops: () => <Backdrops />,
};

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({ section, focus }: { section: string; focus: string | null }) {
  const category = categoryById(section);
  // The theme studio draws appearance.theme and appearance.appTheme itself.
  const studio = category.lead.includes("themeStudio");
  const drawn = new Set([THEME_KEY, APP_THEME_KEY]);
  const groups = category.groups.filter((group) => !(studio && group.rows.every((row) => drawn.has(row.key))));
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} />
      ))}
      {groups.length > 0 && <GroupList groups={groups} focus={focus} />}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
    </div>
  );
}

function CardSlot({ card }: { card: CategoryCard }) {
  return CARDS[card]();
}
