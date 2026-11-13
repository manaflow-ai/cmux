import { CloudEnvironmentsCard } from "./CloudEnvironmentsCard";
import { WorktreeSetupCard } from "./WorktreeSetupCard";
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
import { COMPUTER_USE_ROWS, ComputerUseCard } from "./ComputerUseCard";
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
import { DENSITY_CARD_ROWS } from "../density";
import { DensityCard } from "./DensityCard";
import { BrowserProfiles, MACHINE_COLORS_KEY, MachinesSection, SpacesSection } from "./HostSections";
import { PERSONALIZATION_KEYS, PersonalizationCard } from "./PersonalizationCard";
import { PlaceholderSection } from "./PlaceholderSection";
import { AppUpdateCard } from "./AppUpdateCard";
import { WebUpdatesCard } from "./WebUpdatesCard";
import { VoiceInputCard } from "./VoiceInputCard";
import { ContextMenusCard } from "./ContextMenusCard";
import { ServerCard } from "./ServerCard";
import { SharedLinksCard } from "./SharedLinksCard";
import { TailnetCard } from "./TailnetCard";
import { SectionActions } from "./SectionActions";
import {
  ACCENT_KEY,
  APP_THEME_KEY,
  HIGHLIGHT_COLOR_KEY,
  ROTATE_FAVORITES_KEY,
  THEME_EDITS_KEY,
  THEME_FILE_KEY,
  THEME_KEY,
  ThemeStudio,
} from "./ThemeStudio";
import { arrangeGroups } from "../rowLevels";
import { FAVORITE_THEMES_KEY } from "./ThemePicker";

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

/** Each card; `focus` is the route's focused key (a card may open a panel it names), `workspace`
 * the workspace the page was opened for, `reveal` whether the route opens the page on this card. */
const CARDS: Record<CategoryCard, (focus: string | null, workspace: string | null, reveal: boolean) => ReactNode> = {
  themeStudio: (focus) => <ThemeStudio focus={focus} />,
  terminalInfo: () => <TerminalInfo />,
  ghosttyDiagnostics: () => <GhosttyDiagnostics />,
  computerUse: (focus) => <ComputerUseCard focus={focus} />,
  harnesses: () => <HarnessesCard />,
  spaces: () => <SpacesSection />,
  browserProfiles: () => <BrowserProfiles />,
  machines: (_focus, _workspace, reveal) => <MachinesSection title={machinesTitle()} reveal={reveal} />,
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
  density: (focus) => <DensityCard focus={focus} />,
  importSuggestions: () => <ImportSuggestionsCard />,
  channels: (focus) => <ChannelsCard focus={focus} />,
  appUpdate: () => <AppUpdateCard />,
  webUpdates: () => <WebUpdatesCard />,
  voiceInput: () => <VoiceInputCard />,
  notices: () => <NoticesCard />,
  server: () => <ServerCard />,
  cloudEnvironments: () => <CloudEnvironmentsCard />,
  sharedLinks: (_focus, _workspace, reveal) => <SharedLinksCard reveal={reveal} />,
  tailnet: () => <TailnetCard />,
  worktreeSetup: () => <WorktreeSetupCard />,
  contextMenus: (focus) => <ContextMenusCard focus={focus} />,
  personalization: (focus, workspace) => <PersonalizationCard focus={focus} workspace={workspace} />,
};

/** Every key Personalization draws: its one home on the page. */
// The density card there also draws Text Size and the custom densities (DENSITY_CARD_ROWS).
const HUB_KEYS: ReadonlySet<string> = new Set([...PERSONALIZATION_KEYS, ...DENSITY_CARD_ROWS]);

/** One category: its title, the cards before its groups, the groups, the cards after, actions. */
export function SectionView({
  section,
  focus,
  workspace = null,
  reveal = null,
}: {
  section: string;
  focus: string | null;
  workspace?: string | null;
  /** The card the route opens the page on (`#/settings/machines`), else null. */
  reveal?: CategoryCard | null;
}) {
  const category = categoryById(section);
  // The theme studio draws appearance.theme, appearance.appTheme, appearance.accent,
  // appearance.highlightColor, appearance.rotateFavoriteThemes and appearance.themeFile itself; the
  // schema's group for them would draw each a second time (a second "App Theme" card).
  // Personalization is the one home of what it draws (the theme studio among it): no other page
  // draws those rows, and it does not draw them a second time as rows under its parts.
  const hub = category.lead.includes("personalization");
  const studio = hub || category.lead.includes("themeStudio");
  const drawn = new Set(
    studio ? [THEME_KEY, APP_THEME_KEY, ACCENT_KEY, HIGHLIGHT_COLOR_KEY, ROTATE_FAVORITES_KEY, THEME_FILE_KEY] : [],
  );
  // The background picker draws appearance.background and its Opacity while it shows.
  const picker = useBackdropsShown() && [...category.lead, ...category.trail].includes("backdrops");
  // The Chief Pet card draws home.chiefPetEnabled and home.chiefPetMascot.
  const pet = category.lead.includes("chiefPet");
  // The Chiefs card draws its Engine row (home.chiefEngine).
  const chiefsCard = [...category.lead, ...category.trail].includes("chiefs");
  // The density card draws appearance.density, the custom density keys and Text Size.
  const densityCard = [...category.lead, ...category.trail].includes("density");
  // The Computer Use card draws computerUse.enabled, .driver and .livePreview beside its setup.
  const computerUseCard = [...category.lead, ...category.trail].includes("computerUse");
  // The Machines card draws appearance.machineColors: a color well on each machine's row.
  const machinesCard = [...category.lead, ...category.trail].includes("machines");
  // appearance.themeEdits is the pickers' "(custom)" themes and appearance.favoriteThemes their
  // stars, never rows of their own.
  const groups = category.groups
    .map((group) => ({
      ...group,
      rows: group.rows.filter(
        (row) =>
          row.key !== THEME_EDITS_KEY &&
          row.key !== FAVORITE_THEMES_KEY &&
          !HUB_KEYS.has(row.key) &&
          !drawn.has(row.key) &&
          !(picker && BACKDROP_ROWS.has(row.key)) &&
          !(pet && CHIEF_PET_ROWS.has(row.key)) &&
          !(chiefsCard && CHIEFS_ROWS.has(row.key)) &&
          !(machinesCard && row.key === MACHINE_COLORS_KEY) &&
          !(computerUseCard && COMPUTER_USE_ROWS.has(row.key)) &&
          !(densityCard && DENSITY_CARD_ROWS.has(row.key)),
      ),
    }))
    .filter((group) => group.rows.length > 0);
  // Each row's level and the merged cards (rowLevels.ts). Only Personalization has a jump bar (its own
  // card); a category page is short enough without one (Lucas 2026-11-11).
  const cards = arrangeGroups(category.id, groups, focus);
  return (
    <div className="section" data-section={category.id}>
      <h1 className="section-title">{text(category.title)}</h1>
      {category.lead.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {cards.length > 0 && <GroupList groups={cards} focus={focus} pageTitle={text(category.title)} />}
      {category.trail.map((card) => (
        <CardSlot key={card} card={card} focus={focus} workspace={workspace} reveal={reveal === card} />
      ))}
      {category.actions.map((id) => (
        <SectionActions key={id} section={id} />
      ))}
      {APPEARANCE_CATEGORIES.includes(category.id) && <AppearanceBar />}
    </div>
  );
}

function CardSlot({
  card,
  focus,
  workspace,
  reveal,
}: {
  card: CategoryCard;
  focus: string | null;
  workspace: string | null;
  reveal: boolean;
}) {
  return CARDS[card](focus, workspace, reveal);
}
