import type { ReactNode } from "react";
import { categoryById, type CategoryCard } from "../categories";
import { sections } from "../schema";
import { text } from "../strings";
import { AccountsSection } from "./AccountsSection";
import { AgentHarnesses } from "./AgentHarnesses";
import { AgentIntegrations } from "./AgentIntegrations";
import { CHIEF_PET_ROWS, ChiefPetCard } from "./ChiefPetCard";
import { ChannelsCard } from "./ChannelsCard";
import { CHIEFS_ROWS, ChiefsCard } from "./ChiefsCard";
import { ComputerUseCard } from "./ComputerUseCard";
import { DevicesCard } from "./DevicesCard";
import { GhosttyDiagnostics } from "./GhosttyDiagnostics";
import { GroupList } from "./GroupList";
import { HarnessesCard } from "./HarnessesCard";
import { APPEARANCE_CATEGORIES } from "../appearanceUndo";
import { AppearanceBar } from "./AppearanceBar";
import { MobileCard } from "./MobileCard";
import { NoticesCard } from "./NoticesCard";
import { ImportSuggestionsCard } from "./ImportSuggestionsCard";
import { AdvancedInfo, BACKDROP_ROWS, Backdrops, TerminalInfo, useBackdropsShown } from "./HostCards";
import { DENSITY_ROWS } from "../density";
import { DensityCard } from "./DensityCard";
import { BrowserProfiles, MACHINE_COLORS_KEY, MachinesSection, SpacesSection } from "./HostSections";
import { PlaceholderSection } from "./PlaceholderSection";
import { WebUpdatesCard } from "./WebUpdatesCard";
import { VoiceInputCard } from "./VoiceInputCard";
import { TailnetCard } from "./TailnetCard";
import { ServerCard } from "./ServerCard";
import { SectionActions } from "./SectionActions";
import { ACCENT_KEY, APP_THEME_KEY, THEME_EDITS_KEY, THEME_KEY, ThemeStudio } from "./ThemeStudio";

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

/** Each card; `focus` is the route's focused key (a card may open a panel it names), `workspace`
 * the workspace the page was opened for. */
const CARDS: Record<CategoryCard, (focus: string | null, workspace: string | null) => ReactNode> = {
  themeStudio: (focus) => <ThemeStudio focus={focus} />,
  terminalInfo: () => <TerminalInfo />,
  ghosttyDiagnostics: () => <GhosttyDiagnostics />,
  computerUse: () => <ComputerUseCard />,
  harnesses: () => <HarnessesCard />,
  spaces: () => <SpacesSection />,
  browserProfiles: () => <BrowserProfiles />,
  machines: () => <MachinesSection title={machinesTitle()} />,
  accounts: () => <AccountsSection />,
  agentHarnesses: (focus) => <AgentHarnesses focus={focus} />,
  agentIntegrations: (focus) => <AgentIntegrations focus={focus} />,
  chiefs: (focus) => <ChiefsCard focus={focus} />,
  advancedInfo: () => <AdvancedInfo />,
  advancedActions: () => <PlaceholderSection section="advanced" />,
  backdrops: (focus, workspace) => <Backdrops focus={focus} workspace={workspace} />,
  mobile: () => <MobileCard />,
  devices: () => <DevicesCard />,
  chiefPet: (focus) => <ChiefPetCard focus={focus} />,
  density: () => <DensityCard />,
  importSuggestions: () => <ImportSuggestionsCard />,
  channels: () => <ChannelsCard />,
  webUpdates: () => <WebUpdatesCard />,
  voiceInput: () => <VoiceInputCard />,
  tailnet: () => <TailnetCard />,
  notices: () => <NoticesCard />,
  server: () => <ServerCard />,
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
  // The theme studio draws appearance.theme, appearance.appTheme and appearance.accent itself; the
  // schema's group for them would draw each a second time (a second "App Theme" card).
  const studio = category.lead.includes("themeStudio");
  const drawn = new Set(studio ? [THEME_KEY, APP_THEME_KEY, ACCENT_KEY] : []);
  // The background picker draws appearance.background and its Opacity while it shows.
  const picker = useBackdropsShown() && [...category.lead, ...category.trail].includes("backdrops");
  // The Chief Pet card draws home.chiefPetEnabled and home.chiefPetMascot.
  const pet = category.lead.includes("chiefPet");
  // The Chiefs card draws its Engine row (home.chiefEngine).
  const chiefsCard = [...category.lead, ...category.trail].includes("chiefs");
  // The density card draws appearance.density and the custom density keys.
  const densityCard = [...category.lead, ...category.trail].includes("density");
  // The Machines card draws appearance.machineColors: a color well on each machine's row.
  const machinesCard = [...category.lead, ...category.trail].includes("machines");
  // appearance.themeEdits is the pickers' "(custom)" themes, never a row of its own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          !drawn.has(row.key) &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)) &&
          !(chiefsCard && CHIEFS_ROWS.has(row.key)) &&
          !(machinesCard && row.key === MACHINE_COLORS_KEY) &&
          !(densityCard && DENSITY_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0);
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
      {APPEARANCE_CATEGORIES.includes(category.id) && <AppearanceBar />}
    </div>
  );
}

function CardSlot({ card, focus, workspace }: { card: CategoryCard; focus: string | null; workspace: string | null }) {
  return CARDS[card](focus, workspace);
}
