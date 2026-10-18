import type { ReactNode } from "react";
import { categoryById, type CategoryCard } from "../categories";
import { sections } from "../schema";
import { text } from "../strings";
import { AccountsSection } from "./AccountsSection";
import { AgentHarnesses } from "./AgentHarnesses";
import { CHIEF_PET_ROWS, ChiefPetCard } from "./ChiefPetCard";
import { ComputerUseCard } from "./ComputerUseCard";
import { GhosttyDiagnostics } from "./GhosttyDiagnostics";
import { GroupList } from "./GroupList";
import { HarnessesCard } from "./HarnessesCard";
import { AdvancedInfo, BACKDROP_ROWS, Backdrops, TerminalInfo, useBackdropsShown } from "./HostCards";
import { BrowserProfiles, MachinesSection, SpacesSection } from "./HostSections";
import { PlaceholderSection } from "./PlaceholderSection";
import { SectionActions } from "./SectionActions";
import { APP_THEME_KEY, THEME_EDITS_KEY, THEME_KEY, ThemeStudio } from "./ThemeStudio";

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

/** Each card; `focus` is the route's focused key (a card may open a panel it names), `workspace`
 * the workspace the page was opened for. */
const CARDS: Record<CategoryCard, (focus: string | null, workspace: string | null) => ReactNode> = {
  themeStudio: () => <ThemeStudio />,
  terminalInfo: () => <TerminalInfo />,
  ghosttyDiagnostics: () => <GhosttyDiagnostics />,
  computerUse: () => <ComputerUseCard />,
  harnesses: () => <HarnessesCard />,
  spaces: () => <SpacesSection />,
  browserProfiles: () => <BrowserProfiles />,
  machines: () => <MachinesSection title={machinesTitle()} />,
  accounts: () => <AccountsSection />,
  agentHarnesses: (focus) => <AgentHarnesses focus={focus} />,
  advancedInfo: () => <AdvancedInfo />,
  advancedActions: () => <PlaceholderSection section="advanced" />,
  backdrops: (focus, workspace) => <Backdrops focus={focus} workspace={workspace} />,
  chiefPet: () => <ChiefPetCard />,
};

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({
  section,
  focus,
  workspace = null,
}: {
  section: string;
  focus: string | null;
  workspace?: string | null;
}) {
  const category = categoryById(section);
  // The theme studio draws appearance.theme and appearance.appTheme itself.
  const studio = category.lead.includes("themeStudio");
  const drawn = new Set([THEME_KEY, APP_THEME_KEY]);
  // The background picker draws appearance.background and its Opacity while it shows.
  const picker = useBackdropsShown() && [...category.lead, ...category.trail].includes("backdrops");
  // The Chief Pet card draws home.chiefPetEnabled and home.chiefPetMascot.
  const pet = category.lead.includes("chiefPet");
  // appearance.themeEdits is the pickers' "(custom)" themes, never a row of its own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0 && !(studio && group.rows.every((row) => drawn.has(row.key))));
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} />
      ))}
      {groups.length > 0 && <GroupList groups={groups} focus={focus} />}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
    </div>
  );
}

function CardSlot({ card, focus, workspace }: { card: CategoryCard; focus: string | null; workspace: string | null }) {
  return CARDS[card](focus, workspace);
}
