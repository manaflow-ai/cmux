// Every Settings card loads with its section, not with the page. A card's code (and its art: the
// Chief Pet card's characters, the model catalog the Models card lists) is its own chunk, read the
// first time a section that draws it is ensured (sectionQueries.ts `ensureSection`: the route's
// loader, the hover or focus preload, and the paint gate of the section the page opens on). So the
// page's startup script holds only the frame, the schema rows and the sidebar, and the opening
// section's cards are in before the host shows the page: no card draws a frame late.
import { Suspense, use, type ReactNode } from "react";
import type { CategoryCard } from "../categories";
import { useRouterState } from "@tanstack/react-router";
import { useSettingsRouter } from "../context";
import { sections } from "../schema";
import { text } from "../strings";

/** How a card draws: `focus` is the route's focused key, `workspace` the workspace the page was
 * opened for, `reveal` whether the route opens the page on this card. */
export type CardRender = (focus: string | null, workspace: string | null, reveal: boolean) => ReactNode;

const machinesTitle = () => text(sections.find((section) => section.id === "machines")?.title);

const LOADERS: Record<CategoryCard, () => Promise<CardRender>> = {
  themeStudio: () =>
    import("./ThemeStudio").then(({ ThemeStudio }) => (focus) => <ThemeStudio focus={focus} />),
  terminalInfo: () =>
    import("./HostCards").then(({ TerminalInfo }) => () => <TerminalInfo />),
  ghosttyDiagnostics: () =>
    import("./GhosttyDiagnostics").then(({ GhosttyDiagnostics }) => () => <GhosttyDiagnostics />),
  computerUse: () =>
    import("./ComputerUseCard").then(({ ComputerUseCard }) => (focus) => <ComputerUseCard focus={focus} />),
  harnesses: () =>
    import("./HarnessesCard").then(({ HarnessesCard }) => () => <HarnessesCard />),
  spaces: () =>
    import("./HostSections").then(({ SpacesSection }) => () => <SpacesSection />),
  browserProfiles: () =>
    import("./HostSections").then(({ BrowserProfiles }) => () => <BrowserProfiles />),
  machines: () =>
    import("./HostSections").then(({ MachinesSection }) => (_focus, _workspace, reveal) => (
      <MachinesSection title={machinesTitle()} reveal={reveal} />
    )),
  accounts: () =>
    import("./AccountsSection").then(({ AccountsSection }) => () => <AccountsSection />),
  agentHarnesses: () =>
    import("./AgentHarnesses").then(({ AgentHarnesses }) => (focus) => <AgentHarnesses focus={focus} />),
  agentIntegrations: () =>
    import("./AgentIntegrations").then(({ AgentIntegrations }) => (focus) => <AgentIntegrations focus={focus} />),
  agentCustomization: () =>
    import("./AgentCustomizationCard").then(({ AgentCustomizationCard }) => () => <AgentCustomizationCard />),
  agentTools: () =>
    import("./AgentToolsCard").then(({ AgentToolsCard }) => () => <AgentToolsCard />),
  agentSkills: () =>
    import("./AgentSkillsCard").then(({ AgentSkillsCard }) => () => <AgentSkillsCard />),
  chiefs: () =>
    import("./ChiefsCard").then(({ ChiefsCard }) => (focus) => <ChiefsCard focus={focus} />),
  advancedInfo: () =>
    import("./HostCards").then(({ AdvancedInfo }) => () => <AdvancedInfo />),
  advancedActions: () =>
    import("./PlaceholderSection").then(({ PlaceholderSection }) => () => <PlaceholderSection section="advanced" />),
  backdrops: () =>
    import("./HostCards").then(({ Backdrops }) => (focus, workspace) => (
      <BackdropsSlot Backdrops={Backdrops} focus={focus} workspace={workspace} />
    )),
  mobile: () =>
    import("./MobileCard").then(({ MobileCard }) => () => <MobileCard />),
  devices: () =>
    import("./DevicesCard").then(({ DevicesCard }) => () => <DevicesCard />),
  chiefPet: () =>
    import("./ChiefPetCard").then(({ ChiefPetCard }) => (focus) => <ChiefPetCard focus={focus} />),
  density: () =>
    import("./DensityCard").then(({ DensityCard }) => (focus) => <DensityCard focus={focus} />),
  textSize: () =>
    import("./TextSizeCard").then(({ TextSizeCard }) => () => <TextSizeCard />),
  importSuggestions: () =>
    import("./ImportSuggestionsCard").then(({ ImportSuggestionsCard }) => () => <ImportSuggestionsCard />),
  channels: () =>
    import("./ChannelsCard").then(({ ChannelsCard }) => (focus) => <ChannelsCard focus={focus} />),
  appUpdate: () =>
    import("./AppUpdateCard").then(({ AppUpdateCard }) => () => <AppUpdateCard />),
  webUpdates: () =>
    import("./WebUpdatesCard").then(({ WebUpdatesCard }) => () => <WebUpdatesCard />),
  voiceInput: () =>
    import("./VoiceInputCard").then(({ VoiceInputCard }) => () => <VoiceInputCard />),
  notices: () =>
    import("./NoticesCard").then(({ NoticesCard }) => () => <NoticesCard />),
  server: () =>
    import("./ServerCard").then(({ ServerCard }) => () => <ServerCard />),
  cloudEnvironments: () =>
    import("./CloudEnvironmentsCard").then(({ CloudEnvironmentsCard }) => () => <CloudEnvironmentsCard />),
  cloudModels: () =>
    import("./CloudModelsCard").then(({ CloudModelsCard }) => (focus) => <CloudModelsCard focus={focus} />),
  sharedLinks: () =>
    import("./SharedLinksCard").then(({ SharedLinksCard }) => (_focus, _workspace, reveal) => (
      <SharedLinksCard reveal={reveal} />
    )),
  customizeLibrary: () =>
    import("./CustomizeLibraryCard").then(({ CustomizeLibraryCard }) => (_focus, _workspace, reveal) => (
      <CustomizeLibraryCard reveal={reveal} />
    )),
  customizeChecklist: () =>
    import("./CustomizeChecklist").then(({ CustomizeChecklistCard }) => () => <CustomizeChecklistCard />),
  keys: () =>
    import("./KeysCard").then(({ KeysCard }) => (_focus, _workspace, reveal) => <KeysCard reveal={reveal} />),
  mcpServers: () =>
    import("./McpServersCard").then(({ McpServersCard }) => () => <McpServersCard />),
  tailnet: () =>
    import("./TailnetCard").then(({ TailnetCard }) => () => <TailnetCard />),
  models: () =>
    import("./ModelsCard").then(({ ModelsCard }) => (focus) => <ModelsCard focus={focus} />),
  worktreeSetup: () =>
    import("./WorktreeSetupCard").then(({ WorktreeSetupCard }) => () => <WorktreeSetupCard />),
  contextMenus: () =>
    import("./ContextMenusCard").then(({ ContextMenusCard }) => (focus) => <ContextMenusCard focus={focus} />),
};

/** The background picker. The host adds a fresh `open` token to each Change Background… request:
 * the picker mounts again and reveals the saved tile, even when Appearance already shows. */
function BackdropsSlot({
  Backdrops,
  focus,
  workspace,
}: {
  Backdrops: typeof import("./HostCards").Backdrops;
  focus: string | null;
  workspace: string | null;
}) {
  const router = useSettingsRouter();
  const search = useRouterState({ router, select: (state) => state.location.searchStr });
  const open = new URLSearchParams(search).get("open");
  return <Backdrops key={JSON.stringify([workspace, open])} focus={focus} workspace={workspace} />;
}

/** Every card. */
export const CARD_IDS = Object.keys(LOADERS) as CategoryCard[];

/** A load in flight or done, tagged the way React's `use` reads a settled promise without suspending. */
type Tracked<T> = Promise<T> & { status?: "pending" | "fulfilled"; value?: T };

/** One load per card for the page's life. A failed load draws nothing and is forgotten, so the
 * next ensure of its section reads it again; a load never rejects, so `use` never throws. */
const loads = new Map<CategoryCard, Tracked<CardRender>>();

/** Starts (or joins) the load of `card`'s code. */
export function loadCard(card: CategoryCard): Tracked<CardRender> {
  const known = loads.get(card);
  if (known) return known;
  const load: Tracked<CardRender> = LOADERS[card]().catch((): CardRender => {
    loads.delete(card);
    return () => null;
  });
  load.status = "pending";
  void load.then((render) => {
    load.status = "fulfilled";
    load.value = render;
  });
  loads.set(card, load);
  return load;
}

/** Loads every card in `cards`. */
export async function loadCards(cards: Iterable<CategoryCard>): Promise<void> {
  await Promise.all([...cards].map(loadCard));
}

function LoadedCard({ card, focus, workspace, reveal }: CardProps) {
  const load: Promise<CardRender> = loadCard(card);
  return use(load)(focus, workspace, reveal);
}

type CardProps = {
  card: CategoryCard;
  focus: string | null;
  workspace: string | null;
  reveal: boolean;
};

/** Draws `card`. Its section's ensure loaded it, so it draws in the same frame as the section; a
 * card drawn without one (a search result) shows once its chunk arrives. */
export function Card(props: CardProps) {
  return (
    <Suspense fallback={null}>
      <LoadedCard {...props} />
    </Suspense>
  );
}
