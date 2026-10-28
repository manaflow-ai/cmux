import { authChipText, authText, canSessionLogin } from "./sessionAuth";
import {
  useCallback,
  useContext,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { AgentMark, agentBrand, hasAgentMark, knownMark } from "../shared/AgentMark";
import { agentName, agentDisplayName } from "./agents";
import { agentKey } from "../shared/agentKey";
import { isDefaultChoice } from "./defaultChoice";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { Icon } from "./icons/Icon";
import { usePromptFocus } from "./promptFocus";
import { currentLanguage, useT } from "./i18n";
import { fastModeIsOn, nextFastModeValue } from "./fastModeState";
import { useUpdateOffer } from "./HarnessHealthNotice";
import { CHAT_COLUMN, MODEL_PICKER_MIN_HEIGHT, pickerHeightBounds, type ModelPickerProps } from "./modelPickerLayout";
import { curatedSections, modelSections } from "./modelSections";
import { effortWords, fitsQuery, modelEffort, parseQuery, type ParsedQuery } from "./modelQuery";
import { groupVariants } from "./modelVariants";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import { relevantModelSections } from "./relevantModels";
import { QuickModelMenu, type QuickFamily, type QuickModel } from "./QuickModelMenu";
import type { PickerProfile } from "./pickerProfiles";
import { useUiAnchor } from "../../ui/anchor";
import { useEscapeCloses } from "../../ui/escapeDismiss";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import {
  PickerButton,
  PickerComboboxInput,
  PickerDialog,
  PickerOption,
  PickerOptionList,
} from "../../ui/PickerPrimitives";
import { ScrollArea } from "../../ui/ScrollArea";
import { quantizePickerRail } from "./pickerRailGeometry";

type HarnessChoice = {
  id: string;
  ids: string[];
  name: string;
  models: {
    id: string;
    name?: string;
    shortName?: string;
    family?: string;
    unavailable?: string;
    efforts?: string[];
    fast?: boolean;
    inlineFast?: boolean;
    release?: string;
  }[];
  unavailable?: string;
  acpmuxHarness?: string;
  pickable: boolean;
  /** A profile from the chat's folder and its state. */
  folder?: ModelPickerProps["catalog"][number]["folder"];
  /** The brand the row's mark draws (a folder profile's icon or family, else its id). */
  mark?: string;
  /** The curated models listed first (topModels/); the rest fold under More models. */
  top?: readonly string[];
};

type ModelChoice = {
  id: string;
  name: string;
  family?: string;
  unavailable?: string;
  efforts?: string[];
  fast?: boolean;
  /** The catalog release an alias row stands for, which the curated list names. */
  release?: string;
  /** The compact menu's one row for a model several providers serve: each provider's row. */
  offers?: (ModelChoice & { provider: string })[];
  /** The provider the row lands ("OpenRouter"), for a harness that routes to several. */
  provider?: string;
  /** A bracketed note the model's name carried ("New"). */
  tag?: string;
};

/// `choices` as one row per model (modelVariants.ts): a model several providers serve lands the
/// running provider's row (`model`) while it is available, else the first one that is, and `offers`
/// holds every provider's. A list with no Provider row (search, Starred) would otherwise leave an
/// unavailable running provider as the model's only way in. Its name drops the provider; a
/// bracketed note becomes its `tag`.
function groupChoices(choices: readonly ModelChoice[], model: string | undefined): ModelChoice[] {
  return groupVariants(choices, model).map(({ model: grouped, name, tag, offers }): ModelChoice => {
    const choice = grouped.unavailable ? (offers.find((offer) => !offer.model.unavailable)?.model ?? grouped) : grouped;
    const provider = offers.find((offer) => offer.model === choice)?.provider;
    return {
      ...choice,
      name,
      ...(tag ? { tag } : {}),
      ...(provider ? { provider } : {}),
      ...(offers.length > 1 ? { offers: offers.map((offer) => ({ ...offer.model, provider: offer.provider })) } : {}),
    };
  });
}

function quickSections(
  entry: HarnessChoice | undefined,
  model: string | undefined,
  usable: (choice: ModelChoice) => boolean = () => true,
): { shown: ModelChoice[]; more: ModelChoice[] } {
  const { latest, older } = sectionsFor(entry);
  const all = groupChoices([...latest, ...older], model).filter(usable);
  return relevantModelSections(all, entry?.top);
}

/// A harness's models, each once: its curated top models, else each family's newest (`latest`),
/// then every other model (`older`, folded under More models). The agent-owned default sentinel is not a
/// user-selectable model row. A catalog model names
/// itself by its short name under its harness ("Opus 5.5"). Choices are memoized per harness
/// entry, so the owner map keys stay the same objects between renders.
const choiceCache = new WeakMap<HarnessChoice, { latest: ModelChoice[]; older: ModelChoice[] }>();
function sectionsFor(entry: HarnessChoice | undefined): { latest: ModelChoice[]; older: ModelChoice[] } {
  if (!entry) return { latest: [], older: [] };
  const cached = choiceCache.get(entry);
  if (cached) return cached;
  const seen = new Set<string>();
  const choices = entry.models.flatMap((model): ModelChoice[] => {
    if (isDefaultChoice(model)) return [];
    if (seen.has(model.id)) return [];
    seen.add(model.id);
    return [
      {
        id: model.id,
        name: model.shortName || model.name || model.id,
        ...(model.family ? { family: model.family } : {}),
        unavailable: model.unavailable,
        efforts: model.efforts,
        fast: model.fast,
        ...(model.release ? { release: model.release } : {}),
      },
    ];
  });
  const sections = curatedSections(modelSections(choices, entry.name), entry.top);
  choiceCache.set(entry, sections);
  return sections;
}

/// `sectionsFor`, with the model the chat runs listed after the top ones when it is a folded one
/// (Leo 2026-10-12: a New Tab chip on Claude's default, Sonnet 5, opened the whole fold).
function shownSections(
  entry: HarnessChoice | undefined,
  model: string | undefined,
): { latest: ModelChoice[]; older: ModelChoice[] } {
  const sections = sectionsFor(entry);
  const runs = sections.older.find((choice) => choice.id === model);
  if (!runs) return sections;
  return { latest: [...sections.latest, runs], older: sections.older.filter((choice) => choice !== runs) };
}

/// Every model of a harness, newest first, older versions included.
function choicesFor(entry: HarnessChoice | undefined): ModelChoice[] {
  const { latest, older } = sectionsFor(entry);
  return [...latest, ...older];
}

/// The harness the picker's face draws when the chat names none: its first installed, pickable
/// harness (a bundled catalog harness acpmux does not have is not one), as `current` below picks it.
/// The composer's other chips and the footer's harness item draw the same one (ComposerPickers).
export function pickerFaceHarness(catalog: ModelPickerProps["catalog"]): string | undefined {
  return uniqueHarnesses(catalog)[0]?.id;
}

/// The models a typed query finds among `entries`, each with its harness, in rail order: the full
/// picker's search and the compact menu's search field both list these.
function searchModels(
  entries: readonly HarnessChoice[],
  query: ParsedQuery,
): { model: ModelChoice; entry: HarnessChoice }[] {
  return entries.flatMap((entry) =>
    choicesFor(entry)
      .filter((model) => fitsQuery(model, entry.name, query))
      .map((model) => ({ model, entry })),
  );
}

function uniqueHarnesses(catalog: ModelPickerProps["catalog"]): HarnessChoice[] {
  const profiles: HarnessChoice[] = catalog
    .filter((entry) => entry.folder)
    .map((entry) => ({
      id: entry.id,
      ids: [entry.id],
      name: entry.name,
      models: entry.models,
      unavailable: entry.unavailable,
      acpmuxHarness: entry.id,
      pickable: entry.pickable !== false,
      folder: entry.folder,
      mark: knownMark(entry.icon, entry.family, entry.id),
    }));
  // Terminal and unknown harnesses are routing entries, not installed choices.
  const entries: HarnessChoice[] = catalog
    .filter((entry) => !entry.folder && entry.pickable !== false)
    .map((entry) => ({
      id: entry.id,
      ids: [entry.id],
      name: entry.name,
      models: entry.models,
      unavailable: entry.unavailable,
      acpmuxHarness: entry.id,
      pickable: entry.pickable !== false,
      ...(entry.top ? { top: entry.top } : {}),
    }));
  const result: HarnessChoice[] = [];
  const byName = new Map<string, HarnessChoice>();
  for (const entry of entries) {
    const name = agentName(entry.id, entry.name);
    const existing = byName.get(name);
    if (!existing) {
      const next = {
        id: entry.id,
        ids: [entry.id],
        name,
        models: [...entry.models],
        unavailable: entry.unavailable,
        acpmuxHarness: entry.acpmuxHarness,
        pickable: entry.pickable,
        ...(entry.top ? { top: entry.top } : {}),
      };
      result.push(next);
      byName.set(name, next);
      continue;
    }
    existing.ids.push(entry.id);
    if (entry.acpmuxHarness && !existing.acpmuxHarness) existing.acpmuxHarness = entry.acpmuxHarness;
    existing.pickable ||= entry.pickable;
    const known = new Set(existing.models.map((model) => model.id));
    for (const model of entry.models) if (!known.has(model.id)) existing.models.push(model);
    existing.unavailable ??= entry.unavailable;
    existing.top ??= entry.top;
  }
  return [...result, ...profiles];
}

/// A model as a row of the compact menu's tab `family`, with its providers' rows when it has several.
function quickRow(family: string, model: ModelChoice): QuickModel {
  return {
    id: model.id,
    name: model.name,
    family,
    ...(model.unavailable ? { disabled: true } : {}),
    ...(model.tag ? { tag: model.tag } : {}),
    ...(model.provider ? { provider: model.provider } : {}),
    ...(model.offers
      ? { offers: model.offers.map((offer) => ({ ...quickRow(family, offer), provider: offer.provider })) }
      : {}),
  };
}

/// The rail's Starred tab (never a harness id).
const STARRED = "\u0000starred";

/// Global launch configurations are distinct harness entries, never a Profile submenu.
/// Their model catalogs refresh after selection; do not borrow another account's models.
function railByHarness(
  list: QuickFamily[],
  running: string | undefined,
  profiles: Readonly<Record<string, readonly PickerProfile[]>> = {},
  signedOut: (id: string) => boolean = () => false,
): QuickFamily[] {
  const seen = new Set<string>();
  return list.flatMap((family) => {
    if (seen.has(family.id)) return [];
    seen.add(family.id);
    const folded = profiles[family.id] ?? [];
    const named = folded.map((profile) => ({ ...profile, name: launchName(family.name, profile.name, profile.id) }));
    // Resolve branded suffixes first: `claude-work` becomes Work (work), leaving a profile
    // whose ID is just `work` free to keep Work. Raw IDs distinguish any names still repeated.
    const names = ensureDistinctLaunchNames(
      distinguishLaunchNames(distinguishLaunchNames(named, launchSuffix), readableLaunchId),
    );
    const currentName =
      names.find((profile) => profile.id === family.id)?.name ?? launchName(family.name, family.name, family.id);
    const alternate = launchSuffix(family.id) && family.id !== running;
    const own = { ...family, name: currentName, ...(alternate ? { launch: true } : {}) };
    return [
      own,
      ...names.flatMap((profile): QuickFamily[] => {
        if (
          seen.has(profile.id) ||
          profile.unavailable ||
          signedOut(profile.id) ||
          !profile.name ||
          profile.name === own.name ||
          names.some((other) => other.id !== profile.id && other.name === profile.name)
        )
          return [];
        seen.add(profile.id);
        return [{ id: profile.id, name: profile.name, mark: family.mark, models: [], more: [], launch: true }];
      }),
    ];
  });
}

function distinguishLaunchNames(
  profiles: readonly PickerProfile[],
  suffixFor: (id: string) => string | undefined,
): PickerProfile[] {
  return profiles.map((profile) => {
    const suffix = suffixFor(profile.id);
    return suffix && profiles.some((other) => other.id !== profile.id && other.name === profile.name)
      ? { ...profile, name: `${profile.name} (${suffix})` }
      : profile;
  });
}

/// Keep every readable launch entry when a configured name already contains another entry's suffix.
/// The first entry keeps its readable name; later collisions receive their own readable id.
function ensureDistinctLaunchNames(profiles: readonly PickerProfile[]): PickerProfile[] {
  const used = new Set<string>();
  return profiles.map((profile) => {
    if (!used.has(profile.name)) {
      used.add(profile.name);
      return profile;
    }
    const suffix = readableLaunchId(profile.id) ?? profile.id;
    let name = `${profile.name} (${suffix})`;
    let index = 2;
    while (used.has(name)) name = `${profile.name} (${suffix} ${index++})`;
    used.add(name);
    return { ...profile, name };
  });
}

/// Prefer a configured readable name; distinguish generic brand names by a meaningful id suffix.
function launchName(brand: string, configured: string, id: string): string {
  const base = agentKey(id);
  const canonical = agentDisplayName(id);
  if (configured !== canonical && configured !== id) return configured;
  const suffix = launchSuffix(id);
  if (suffix) return `${brand} (${suffix})`;
  return configured === id && base ? brand : configured;
}

function launchSuffix(id: string): string | undefined {
  const base = agentKey(id);
  if (!agentBrand(id) || !base || !id.toLowerCase().startsWith(base)) return undefined;
  const suffix = id.slice(base.length).replace(/^[-_\s]+/, "");
  return readableLaunchId(suffix);
}

function readableLaunchId(id: string): string | undefined {
  return id.length <= 32 && /^[a-z][a-z0-9_-]*$/i.test(id) ? id : undefined;
}

/// A folder profile row the user cannot start yet: waiting for the folder's Trust answer, or broken.
const blockedProfile = (entry: HarnessChoice | undefined) =>
  entry?.folder?.state === "needs-trust" || entry?.folder?.state === "error";

/// A rail tab: a plain icon on a round wash, filled while its models show (no square tile; Leo
/// 2026-10-18).
const railTab =
  "acpmux-mp-rail-tab grid size-8 flex-none cursor-pointer place-items-center rounded-full border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg aria-selected:bg-hover aria-selected:text-fg disabled:cursor-default disabled:opacity-50 aria-disabled:opacity-50";
/// A model row: one line, the theme's text. The fill is separate (`rowFill`): two background
/// utilities on one element resolve by Tailwind's output order, not by the class list.
const modelRow =
  "flex h-[var(--ui-row-height,28px)] w-full cursor-pointer items-center gap-2 rounded-[var(--ui-row-radius,5px)] border-0 px-2 text-left font-[inherit] text-control text-fg disabled:cursor-default disabled:opacity-50";
/// The active row (pointer or arrows) has the hover wash; any other row gets it on hover.
const rowFill = (active: boolean) => (active ? "bg-hover" : "bg-transparent hover:bg-hover");
const emptyNote = "px-2.5 py-2 text-body text-muted";
/// The update row's Update and Skip This Version: row-height text buttons, as wide as their words.
const updateButton =
  "flex h-[var(--ui-row-height,28px)] flex-none cursor-pointer items-center rounded-[var(--ui-row-radius,5px)] border-0 px-2 font-[inherit] text-control text-fg";

function StarGlyph({ filled, size }: { filled: boolean; size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true" className="block">
      <path
        d="M8 1.6l1.95 4.02 4.4.6-3.2 3.08.78 4.38L8 11.6l-3.93 2.08.78-4.38-3.2-3.08 4.4-.6z"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/// The composer model picker: one harness-and-model button opens a stable two-column picker.
/// The real search field receives focus immediately, and the selected harness's fixed model order
/// keeps keyboard muscle memory intact between openings.
export function ModelPicker(props: ModelPickerProps) {
  const {
    catalog,
    harness,
    label,
    chip,
    switching,
    onLand,
    onHarness,
    onHarnessHint,
    onHarnessEnable,
    onCombo,
    fastMode,
    catalogRefresh,
    signedOut,
    onLogIn,
    usage,
    quick,
    detail,
    detailShort,
    fork,
  } = props;
  /// A signed-out harness's login command ("" when acpmux names none); undefined when it can start.
  const loginFor = useCallback((entry: HarnessChoice) => signedOut?.[entry.acpmuxHarness ?? entry.id], [signedOut]);
  const t = useT();
  const newTab = useContext(OnNewTab);
  /// The chat's agent CLI has an update (hq#2569 #12): a row in the menu and the picker and a line
  /// in the chip's tooltip, never a banner over the chat. Never a dot on the chip: drawn between the
  /// model and its effort it read "Opus 5.5 • Medium" (Leo 2026-10-21: "WE FUCKING HATE THE DOT").
  const update = useUpdateOffer();
  const updateText = update
    ? t("harness.outdated", { agent: update.agent, version: update.version, latest: update.latest })
    : undefined;
  const modelText = t(PICKER_LABELS.model);
  const searchText = t("picker.search");
  const harnessText = t("picker.harness");
  const noMatchesText = t("picker.noMatches");
  const starredText = t("picker.starred");
  const addHarnessText = t("modelPicker.addHarness");
  const fastText = t("picker.fastOn");
  const unavailableText = t("picker.unavailable");
  const modelRowId = (id: string) => `${menuId}-model-${encodeURIComponent(id)}`;
  const [open, setOpen] = useState(false);
  // The compact menu (QuickModelMenu) a click opens when `quick` is set; More models opens the full one.
  const [quickOpen, setQuickOpen] = useState(false);
  const [openHeight, setOpenHeight] = useState<number>();
  const [selectedHarness, setSelectedHarness] = useState(harness);
  const [activeHarness, setActiveHarness] = useState(0);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  // On an empty list the add row is the only stop; it is current only once an arrow or the pointer
  // reaches it, so Return on a search with no match does not open the Harnesses page.
  const [addChosen, setAddChosen] = useState(false);
  const [olderOpen, setOlderOpen] = useState(false);
  const [favorites, setFavorites] = useState<Set<string>>(() => {
    try {
      const stored = globalThis.localStorage?.getItem("cmux.model-picker.favorites");
      return stored ? new Set(JSON.parse(stored) as string[]) : new Set<string>();
    } catch {
      return new Set<string>();
    }
  });
  const [localRefreshStatus, setLocalRefreshStatus] = useState<"fetching" | "updated" | "error">();
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const restoreFocus = useRef(false);
  // A pick hands the keyboard to the composer's prompt, not back to the model button (promptFocus.ts).
  const toPrompt = useRef(false);
  const focusPrompt = usePromptFocus();
  // The compact menu's pick does the same once the menu has closed: while it is open it keeps the
  // keyboard on its rows, and its close leaves focus where the pick put it (ui/Menu.tsx).
  const quickPicked = useRef(false);
  const menuId = useId();
  const allHarnesses = useMemo(
    () => uniqueHarnesses(catalog.filter((entry) => entry.id !== "unii" || harness === "unii")),
    [catalog, harness],
  );
  // A started chat lists its own harness alone. One acpmux has not listed yet (the first open after
  // launch) keeps the whole rail rather than an empty menu.
  const ownHarness = useMemo(
    () => allHarnesses.filter((entry) => entry.ids.includes(harness ?? "")),
    [allHarnesses, harness],
  );
  const harnessFixed = props.harnessFixed === true && ownHarness.length > 0;
  const harnesses = harnessFixed ? ownHarness : allHarnesses;
  // Folder profiles remain available for the current machine's models and trust/enable state, but
  // they are not harness choices and never become tabs in the picker rail.
  const railHarnesses = useMemo(() => harnesses.filter((entry) => !entry.folder), [harnesses]);
  // A started chat offers no other harness, so it has no Add harness… row either.
  const onAddAgent = harnessFixed ? undefined : props.onAddAgent;
  const navigableHarnesses = useMemo(
    () =>
      railHarnesses
        .map((entry, index) => ({ entry, index }))
        .filter(({ entry }) => entry.pickable && !blockedProfile(entry)),
    [railHarnesses],
  );
  const current = harnesses.find((entry) => entry.ids.includes(harness ?? "")) ?? harnesses[0];
  // The rail's first tab lists the starred models of every harness; each row keeps its harness.
  const starredView = selectedHarness === STARRED;
  const selected = starredView
    ? undefined
    : (harnesses.find((entry) => entry.ids.includes(selectedHarness ?? "")) ?? current);
  // A typed query searches every harness; without one, the rail's tab picks the list.
  const vocabulary = useMemo(() => effortWords(harnesses.flatMap((entry) => entry.models)), [harnesses]);
  const parsed = useMemo(() => parseQuery(query, vocabulary), [query, vocabulary]);
  const searching = query.trim() !== "";
  // The chat's model, on its own harness's tab only.
  const runsHere = selected?.ids.includes(harness ?? "") ? props.model : undefined;
  const owners = useMemo(() => {
    const owner = new Map<ModelChoice, HarnessChoice>();
    if (searching) {
      const searchable = harnesses.filter(
        (entry) => entry.pickable && !blockedProfile(entry) && loginFor(entry) === undefined,
      );
      for (const { model, entry } of searchModels(searchable, parsed)) owner.set(model, entry);
    } else if (starredView) {
      for (const entry of harnesses)
        if (!entry.folder && loginFor(entry) === undefined)
          for (const model of choicesFor(entry)) if (favorites.has(model.id)) owner.set(model, entry);
    } else if (selected && loginFor(selected) === undefined) {
      // Every model past the top ones folds under More models until it opens (cx-jqkx, cx-espus).
      const { latest, older } = shownSections(selected, runsHere);
      for (const model of olderOpen ? [...latest, ...older] : latest) owner.set(model, selected);
    }
    return owner;
  }, [favorites, harnesses, olderOpen, parsed, searching, selected, starredView, runsHere, loginFor]);
  const visible = useMemo(() => [...owners.keys()], [owners]);
  // Add harness… is the list's last row, after the models: arrows reach it like a model row.
  const addRow = onAddAgent ? visible.length : -1;
  const rowCount = visible.length + (onAddAgent ? 1 : 0);
  const addRowId = `${menuId}-add-harness`;
  const onAddRow = active === addRow && (visible.length > 0 || addChosen);
  const olderCount =
    searching || starredView || (selected && loginFor(selected) !== undefined)
      ? 0
      : shownSections(selected, runsHere).older.length;
  const refreshStatus = localRefreshStatus ?? catalogRefresh?.status ?? "idle";
  const refreshDate = catalogRefresh?.date;
  const formattedRefreshDate = refreshDate
    ? new Intl.DateTimeFormat(currentLanguage(), {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(new Date(refreshDate))
    : undefined;
  const refreshTitle = (() => {
    const label =
      refreshStatus === "fetching"
        ? t("picker.catalogRefreshing")
        : refreshStatus === "error"
          ? t("picker.catalogRefreshError")
          : formattedRefreshDate
            ? t("picker.catalogUpdated", { date: formattedRefreshDate })
            : t("picker.refreshCatalog");
    return formattedRefreshDate && (refreshStatus === "fetching" || refreshStatus === "error")
      ? `${label} · ${formattedRefreshDate}`
      : label;
  })();
  useEffect(() => {
    // A host event is authoritative: let its fetching, updated, or error state replace
    // the local promise state from the previous click.
    if (catalogRefresh?.status && catalogRefresh.status !== "idle") setLocalRefreshStatus(undefined);
  }, [catalogRefresh?.date, catalogRefresh?.status]);
  // Opens on the side that has room for the picker's floor, not only for what it measures before its
  // models load: above the chip, else below it (Leo: the menu stays inside the page). On New Tab,
  // below first (newTabComposer.ts).
  const menuStyle = useUiAnchor(trigger, menu, open, {
    side: newTab ? "below" : "above",
    align: "start",
    minHeight: MODEL_PICKER_MIN_HEIGHT,
    // Inside the chat column, never over the session rail or sidebar beside it.
    boundary: CHAT_COLUMN,
  });
  useLayoutEffect(() => {
    if (!open) {
      setOpenHeight(undefined);
      return;
    }
    if (menuStyle.visibility !== "visible" || openHeight != null) return;
    const node = menu.current;
    if (node) setOpenHeight(Math.ceil(node.getBoundingClientRect().height));
  }, [menuStyle.visibility, open, openHeight]);
  // Quantize the narrow horizontal harness rail to complete cells. A fractional viewport
  // leaves the browser's maximum scroll position between snap points, which would expose a
  // clipped mark at the far edge. Measure the stable menu container, never the width we set,
  // and leave fitting rails untouched.
  useLayoutEffect(() => {
    if (!open || menuStyle.visibility !== "visible") return;
    const rail = menu.current?.querySelector<HTMLElement>(".acpmux-mp-rail-scroll");
    const container = rail?.parentElement;
    const viewport = rail?.querySelector<HTMLElement>(".acpmux-mp-rail-viewport");
    const list = rail?.querySelector<HTMLElement>(".acpmux-mp-rail-list");
    if (!rail || !container || !viewport || !list) return;
    const matchMedia = globalThis.matchMedia;
    const ResizeObserverImpl = globalThis.ResizeObserver;
    if (typeof matchMedia !== "function" || typeof ResizeObserverImpl !== "function") return;
    const quantize = () => {
      quantizePickerRail(rail, container, viewport, matchMedia.call(globalThis, "(max-width: 407px)").matches);
    };
    quantize();
    const observer = new ResizeObserverImpl(quantize);
    observer.observe(container);
    observer.observe(list);
    const media = matchMedia.call(globalThis, "(max-width: 407px)");
    media.addEventListener?.("change", quantize);
    return () => {
      observer.disconnect();
      media.removeEventListener?.("change", quantize);
      rail.style.removeProperty("width");
    };
  }, [menuStyle.visibility, open, harnessFixed, railHarnesses.length]);
  const close = useCallback(
    (focus = true) => {
      restoreFocus.current = focus;
      setOpen(false);
      onHarnessHint?.(undefined);
    },
    [onHarnessHint],
  );
  useEffect(() => {
    if (open) return;
    // A pick's prompt focus belongs to its own close: a reopen before the frames below run cancels
    // them, and the next close (Escape) returns to the model button.
    const picked = toPrompt.current;
    toPrompt.current = false;
    if (!restoreFocus.current) return;
    restoreFocus.current = false;
    // A pointerup can still apply its default focus after React closes the popup. Defer the
    // restoration until that browser action has finished. A second frame also covers the
    // narrow drill's late focus handoff, matching the popup's final focus contract for
    // press-drag-release selection.
    let second: number | undefined;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => {
        if (!(picked && focusPrompt())) trigger.current?.focus({ preventScroll: true });
      });
    });
    return () => {
      cancelAnimationFrame(first);
      if (second !== undefined) cancelAnimationFrame(second);
    };
  }, [open, focusPrompt]);
  useEffect(() => {
    if (quickOpen || !quickPicked.current) return;
    quickPicked.current = false;
    focusPrompt();
  }, [quickOpen, focusPrompt]);
  const show = useCallback(() => {
    setSelectedHarness(harness ?? current?.id);
    setActiveHarness(
      Math.max(
        0,
        railHarnesses.findIndex((entry) => entry.ids.includes(harness ?? "")),
      ),
    );
    setQuery("");
    // Cmd-Ctrl-M or automation over the compact menu: the full picker replaces it.
    setQuickOpen(false);
    // The fold opens closed; a session on a folded model has its row with the top ones, highlighted.
    setOlderOpen(false);
    setActive(
      Math.max(
        0,
        shownSections(current, current?.ids.includes(harness ?? "") ? props.model : undefined).latest.findIndex(
          (model) => model.id === props.model,
        ),
      ),
    );
    setOpen(true);
    if (open) search.current?.focus();
    else trigger.current?.focus();
  }, [current, harness, open, props.model, railHarnesses]);
  const showRef = useRef(show);
  showRef.current = show;
  const toggle = open ? (_next: boolean) => close() : setOpen;
  const press = usePopoverTrigger(open, toggle, show);
  const more = (typed?: string) => {
    setQuickOpen(false);
    show();
    if (typed) {
      setQuery(typed);
      setActive(0);
      setAddChosen(false);
    }
  };
  useEscapeCloses(open, close);

  useLayoutEffect(() => {
    // The anchor's first render is hidden while it measures. Browsers cannot focus search
    // until the positioned menu is visible, even though JSDOM accepts that early focus.
    if (open && menuStyle.visibility === "visible") search.current?.focus({ preventScroll: true });
  }, [open, menuStyle.visibility]);
  // The highlighted row stays in view (Lawrence 2026-10-09 recording: ArrowDown moved the highlight below the
  // visible rows and the list did not follow). The nearest scroll only moves when the row is outside the list's
  // viewport, so a pointer hover (always over a visible row) never scrolls.
  const activeRowId = visible[active] ? modelRowId(visible[active].id) : onAddRow ? addRowId : undefined;
  useLayoutEffect(() => {
    if (!open || !activeRowId) return;
    menu.current?.ownerDocument.getElementById(activeRowId)?.scrollIntoView?.({ block: "nearest" });
  }, [open, activeRowId]);
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) close(false);
    };
    const blur = () => close(false);
    // In the capture phase, as Base UI's menus close: a press outside only closes the picker, and
    // nothing under it sees the press (menuPressGuard.ts).
    document.addEventListener("pointerdown", away, true);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away, true);
      window.removeEventListener("blur", blur);
    };
  }, [close, open]);
  useEffect(
    () =>
      registerPicker(modelText, () =>
        quick !== undefined ? (open ? close() : setQuickOpen(true)) : showRef.current(),
      ),
    [modelText, quick, open, close],
  );
  // The footer's harness item opens this menu: its rail is the composer's harness switcher.
  const opener = props.opener;
  const compact = quick !== undefined;
  useEffect(() => {
    if (!opener) return;
    const openMenu = () => (compact ? (open ? close() : setQuickOpen(true)) : showRef.current());
    opener.current = openMenu;
    return () => {
      if (opener.current === openMenu) opener.current = undefined;
    };
  }, [opener, compact, open, close]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      // Cmd-Ctrl-M opens the picker (Lawrence 2026-10-08); typing then searches every harness.
      if (event.metaKey && event.ctrlKey && !event.altKey && event.key.toLowerCase() === "m") {
        event.preventDefault();
        if (quick !== undefined) {
          if (open) close();
          else setQuickOpen(true);
        } else showRef.current();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [quick, open, close]);
  useEffect(() => {
    if (!open) setSelectedHarness(harness);
  }, [harness, open]);
  useEffect(() => {
    if (active >= rowCount) setActive(Math.max(rowCount - 1, 0));
  }, [active, rowCount]);

  const selectModel = (model: ModelChoice) => {
    const owner = owners.get(model);
    if (model.unavailable || !owner?.pickable || loginFor(owner) !== undefined) return;
    toPrompt.current = true;
    // A typed effort or fast mode, or a model of another harness, lands as one combo.
    const effort = searching ? modelEffort(model, parsed.effort) : undefined;
    const fast = searching ? parsed.fast : undefined;
    const harnessId = owner.acpmuxHarness ?? owner.id;
    if (onCombo && (effort || fast || !owner.ids.includes(harness ?? ""))) {
      onCombo({ harness: harnessId, model: model.id, effort, fast });
      close();
      return;
    }
    if (!owner.ids.includes(harness ?? "")) {
      if (owner.acpmuxHarness) onHarness?.(owner.acpmuxHarness);
      close();
      return;
    }
    onLand(model.id);
    close();
  };
  /// The compact menu's search field: the full picker's search over the harnesses the menu offers.
  /// A row names its harness when the menu has a rail, and the effort and fast mode the query named
  /// ("gpt high fast"), which its pick lands with.
  const quickSearch = (text: string): QuickModel[] => {
    const typed = parseQuery(text, vocabulary);
    // The chat's own harness once it has started, else every one the rail offers.
    const searchable = (harnessFixed ? ownHarness : harnesses).filter(
      (entry) =>
        entry.pickable &&
        !blockedProfile(entry) &&
        entry.folder?.state !== "needs-enable" &&
        loginFor(entry) === undefined,
    );
    const found = searchModels(searchable, typed);
    // A model several providers serve is one match, in the place of its best-ranked provider's row.
    const groupOf = new Map<ModelChoice, ModelChoice>();
    for (const entry of new Set(found.map((match) => match.entry))) {
      const matches = found.filter((match) => match.entry === entry).map((match) => match.model);
      for (const group of groupChoices(matches, entry.ids.includes(harness ?? "") ? props.model : undefined))
        for (const member of group.offers ?? [group])
          groupOf.set(
            matches.find((match) => match.id === member.id)!,
            group,
          );
    }
    const seen = new Set<ModelChoice>();
    return found.flatMap(({ model: match, entry }) => {
      const model = groupOf.get(match) ?? match;
      if (seen.has(model)) return [];
      seen.add(model);
      const effort = modelEffort(model, typed.effort);
      const hint = [!harnessFixed ? entry.name : undefined, model.provider, effort, typed.fast ? fastText : undefined]
        .filter(Boolean)
        .join(" · ");
      const row = quickRow(entry.id, model);
      return [
        {
          ...row,
          ...(hint ? { hint } : {}),
          ...(effort ? { effort } : {}),
          ...(typed.fast ? { fast: true } : {}),
        },
      ];
    });
  };
  // The compact menu's rail (Leo 2026-10-18): Starred when any model is starred, then each harness
  // that can start here, its top models numbered and the rest under More models.
  const quickFamilies = useMemo(() => {
    // A started chat's compact menu lists its own harness's models with no rail; More models
    // opens the full picker, which has no rail either.
    // A folder profile is a machine choice, so its current models stay in the plain compact list
    // while the harness-only rail remains absent.
    if (!quick || (harnessFixed && !fork) || current?.folder) return undefined;
    const row = (entry: HarnessChoice, model: ModelChoice) => quickRow(entry.id, model);
    // A started chat that forks lists every harness, as a New Tab does; its own stays the chat's.
    const startable = (fork ? allHarnesses : harnesses).filter(
      (entry) => !entry.folder && entry.pickable && !blockedProfile(entry),
    );
    const list: QuickFamily[] = [];
    const starred = startable
      .filter((entry) => loginFor(entry) === undefined)
      .flatMap((entry) =>
        groupChoices(
          choicesFor(entry).filter((model) => favorites.has(model.id)),
          entry.ids.includes(harness ?? "") ? props.model : undefined,
        ).map((model) => row(entry, model)),
      );
    if (starred.length) list.push({ id: STARRED, name: starredText, starred: true, models: starred, more: [] });
    for (const entry of startable) {
      const signedOutHere = loginFor(entry) !== undefined;
      const { shown, more } = signedOutHere
        ? { shown: [], more: [] }
        : quickSections(entry, entry.ids.includes(harness ?? "") ? props.model : undefined);
      list.push({
        id: entry.id,
        name: entry.name,
        ...(hasAgentMark(entry.mark ?? entry.id) ? { mark: entry.mark ?? entry.id } : {}),
        models: shown.map((model) => row(entry, model)),
        more: more.map((model) => row(entry, model)),
        ...(signedOutHere ? { note: t("harnesses.signedOut") } : {}),
        ...(signedOutHere && loginFor(entry) && onLogIn
          ? { logIn: () => onLogIn(entry.acpmuxHarness ?? entry.id, loginFor(entry)!) }
          : {}),
      });
    }
    const rail = railByHarness(list, harness ?? current?.id, props.profiles, (id) => signedOut?.[id] !== undefined);
    if (!harnessFixed) return rail;
    // A started chat (Leo 2026-10-22: "can expose as fork"): another harness's tab is Fork to it,
    // Starred keeps the chat's own models, and another launch profile of any harness forks there.
    return rail.flatMap((family): QuickFamily[] => {
      const own = family;
      if (family.starred) {
        const models = family.models.filter((model) => model.family === current?.id);
        return models.length ? [{ ...family, models }] : [];
      }
      if (family.id === current?.id || family.note) return [own];
      if (family.launch) return [{ ...own, models: [], more: [], fork: true }];
      return [{ ...own, models: [], more: [], fork: true }];
    });
  }, [
    quick,
    harnessFixed,
    fork,
    allHarnesses,
    harnesses,
    current?.id,
    current?.folder,
    loginFor,
    favorites,
    starredText,
    harness,
    props.model,
    t,
    onLogIn,
    props.profiles,
    signedOut,
  ]);
  /// A compact-menu pick: this harness's model lands in place; another harness's starts a chat there.
  /// A searched row with an effort or fast mode lands as one combo, as the full picker's does.
  const pickQuick = (model: QuickModel) => {
    const owner = harnesses.find((entry) => entry.id === model.family);
    if (!owner || model.disabled || !owner.pickable || loginFor(owner) !== undefined) return;
    const harnessId = owner.acpmuxHarness ?? owner.id;
    const here = owner.ids.includes(harness ?? "");
    if (onCombo && (model.effort || model.fast || !here)) {
      onCombo({ harness: harnessId, model: model.id, effort: model.effort, fast: model.fast });
      return;
    }
    if (here) {
      onLand(model.id);
      return;
    }
    if (owner.acpmuxHarness) onHarness?.(owner.acpmuxHarness);
  };
  /// A compact-menu pick from the rail or the search: the prompt takes the keyboard once it closes.
  const pickQuickToPrompt = (model: QuickModel) => {
    quickPicked.current = true;
    pickQuick(model);
  };
  /// An Account pick: the harness's other profile starts a chat there, or forks a started chat there.
  /// `id` is an acpmux profile: one a tab folded (pickerProfiles.ts) is no harness entry of its own.
  const pickProfile = (id: string) => {
    if (id === harness || signedOut?.[id] !== undefined) return;
    const owner = allHarnesses.find((entry) => entry.id === id);
    if (owner && loginFor(owner) !== undefined) return;
    const target = owner?.acpmuxHarness ?? id;
    if (harnessFixed) {
      if (fork?.ready) fork.to(target);
    } else onHarness?.(target);
  };
  const addHarness = () => {
    close();
    onAddAgent?.();
  };
  const refreshCatalog = () => {
    if (!catalogRefresh || refreshStatus === "fetching") return;
    setLocalRefreshStatus("fetching");
    try {
      Promise.resolve(catalogRefresh.refresh()).then(
        () => setLocalRefreshStatus("updated"),
        () => setLocalRefreshStatus("error"),
      );
    } catch {
      setLocalRefreshStatus("error");
    }
  };
  const toggleFavorite = (modelId: string) => {
    setFavorites((current) => {
      const next = new Set(current);
      if (next.has(modelId)) next.delete(modelId);
      else next.add(modelId);
      try {
        globalThis.localStorage?.setItem("cmux.model-picker.favorites", JSON.stringify([...next]));
      } catch {
        // Storage is optional in gallery and private browsing contexts.
      }
      return next;
    });
  };
  /// Shows a rail tab's models (click or arrow key); `clear` drops the typed query.
  const showTab = (id: string | undefined, index: number, clear = false) => {
    if (clear && query) setQuery("");
    else if (searching) return;
    if (id === undefined || id === selectedHarness) return;
    setSelectedHarness(id);
    setOlderOpen(false);
    if (index >= 0) setActiveHarness(index);
    setActive(0);
    setAddChosen(false);
  };
  // The rail is Starred, then the pickable harnesses. Disabled or blocked profiles stay visible
  // for context but are never a keyboard stop. Reaching either end returns to Starred.
  const nextRailIndex = (from: number, step: number) => {
    if (!navigableHarnesses.length) return -1;
    if (from < 0) return step > 0 ? navigableHarnesses[0]!.index : navigableHarnesses.at(-1)!.index;
    const position = navigableHarnesses.findIndex(({ index }) => index === from);
    if (position < 0) {
      const nearby =
        step > 0
          ? navigableHarnesses.find(({ index }) => index > from)
          : [...navigableHarnesses].reverse().find(({ index }) => index < from);
      return nearby?.index ?? -1;
    }
    const next = position + step;
    return next < 0 || next >= navigableHarnesses.length ? -1 : navigableHarnesses[next]!.index;
  };
  const focusRail = (index: number) => {
    if (index < 0) {
      menu.current?.querySelector<HTMLButtonElement>(".acpmux-mp-rail-tab[aria-label]")?.focus();
      return;
    }
    menu.current?.querySelector<HTMLElement>(`[data-harness-index="${index}"]`)?.focus();
  };
  const moveRail = (from: number, step: number) => {
    const next = nextRailIndex(from, step);
    if (next < 0) {
      showTab(STARRED, -1);
      focusRail(-1);
    } else {
      showTab(railHarnesses[next]?.id, next);
      focusRail(next);
    }
  };
  const move = (step: number) => {
    // Moving down past the last row opens the More models fold, so keys reach every model.
    if (step > 0 && !olderOpen && olderCount > 0 && active >= visible.length - 1 && active !== addRow) {
      setOlderOpen(true);
      setActive(visible.length);
      return;
    }
    setActive((index) => (rowCount ? (index + step + rowCount) % rowCount : 0));
    setAddChosen(true);
  };
  const keyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    // Candidate acceptance belongs to the IME. WebKit can report only keyCode 229 on commit.
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const shortcut = event.ctrlKey && ["n", "p", "j", "k"].includes(event.key.toLowerCase());
    if (shortcut) {
      event.preventDefault();
      move(["n", "j"].includes(event.key.toLowerCase()) ? 1 : -1);
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      move(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      move(-1);
    } else if (event.key === "ArrowLeft" && !query && !harnessFixed) {
      event.preventDefault();
      if (starredView) focusRail(-1);
      else focusRail(activeHarness);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const model = visible[active];
      if (model) selectModel(model);
      else if (onAddRow) addHarness();
    } else if (
      /^[1-9]$/.test(event.key) &&
      !event.ctrlKey &&
      !event.altKey &&
      !query &&
      (!event.metaKey || Number(event.key) <= 4)
    ) {
      const model = visible[Number(event.key) - 1];
      if (model) {
        event.preventDefault();
        selectModel(model);
      }
    } else if (event.key === "Escape") {
      event.preventDefault();
      close();
      trigger.current?.focus();
    }
  };
  // The chip draws one harness: the one a switch to another harness is starting, else the running
  // one. Browsing another harness in the open menu changes neither its mark nor its name.
  const switchingTo = switching && !current?.ids.includes(switching.harness) ? switching : undefined;
  // A folder profile draws its own mark (its icon or family), as its rail tab does, not its id's.
  // A switch draws its target's mark: the one it names, else that harness's own.
  const switchingMark = switchingTo
    ? (switchingTo.mark ??
      harnesses.find((entry) => entry.ids.includes(switchingTo.harness))?.mark ??
      switchingTo.harness)
    : undefined;
  const chipHarness = switchingMark ?? current?.mark ?? current?.id ?? harness;
  const chipLabel = switchingTo?.name ?? label;
  // The controls row's forms of the chip (composerRowFit.ts); a switch draws its target's name whole.
  const rowChip = switchingTo ? undefined : chip;
  // The name the chip writes: without the vendor its mark draws ("Opus 5.5"), the title keeps it whole.
  const chipName = switchingTo ? chipLabel : withoutVendor(chipLabel, chipHarness);
  const chipShort = rowChip?.short && rowChip.short !== chipName ? rowChip.short : undefined;
  const chipFamily = rowChip?.family && rowChip.family !== (chipShort ?? chipName) ? rowChip.family : undefined;
  const chipTitle = rowChip?.title ?? chipLabel;
  const sessionAuthText = authText(props.sessionAuth, t);
  const sessionAuthChip = authChipText(props.sessionAuth, t);
  const enableProfile = (entry: HarnessChoice) => {
    if (entry.folder?.state !== "needs-enable" || entry.ids.includes(harness ?? "")) return false;
    onHarnessEnable?.(entry.folder.folder, entry.id);
    close();
    return true;
  };
  const folderNote = (entry: HarnessChoice) =>
    entry.folder?.state === "needs-enable"
      ? t("picker.enableHarness")
      : entry.folder?.state === "needs-trust"
        ? t("picker.needsTrust")
        : entry.folder?.state === "error"
          ? unavailableText
          : undefined;
  const selectedOther = selected !== undefined && !selected.ids.includes(harness ?? "");
  const folderProfiles = harnesses.filter((entry) => entry.folder);
  // Several harness profiles can draw one brand's mark (Claude Code, Claude Agent, a subrouter
  // route): their tooltips add the profile id, so each tab says which one it starts.
  const markCounts = new Map<string, number>();
  for (const entry of harnesses) {
    const mark = entry.mark ?? agentBrand(entry.id) ?? entry.id;
    markCounts.set(mark, (markCounts.get(mark) ?? 0) + 1);
  }
  const railTitle = (entry: HarnessChoice) => {
    const mark = entry.mark ?? agentBrand(entry.id) ?? entry.id;
    const shared = (markCounts.get(mark) ?? 0) > 1 && entry.name !== entry.id;
    const signIn = loginFor(entry) !== undefined ? t("harnesses.signedOut") : undefined;
    return [shared ? `${entry.name} (${entry.id})` : entry.name, folderNote(entry), signIn].filter(Boolean).join(" · ");
  };
  const chipFace = (
    <>
      <AgentMark agent={chipHarness} size={15} />
      {sessionAuthChip && (
        <span className="acpmux-model-detail" aria-label={sessionAuthText}>
          {sessionAuthChip}
        </span>
      )}
      <span
        className="acpmux-model-name"
        {...(chipShort
          ? { "data-short": "" }
          : { "data-fit-part": "model", "data-fit-forms": chipFamily ? "full" : "full family" })}
      >
        {chipName}
      </span>
      {/* The row's forms are drawn, not written: the chip's text stays the model's name. */}
      {chipShort && (
        <span
          className="acpmux-model-short acpmux-fit-label"
          data-fit-part="model"
          data-fit-forms={chipFamily ? "full" : "full family"}
          data-label={chipShort}
        />
      )}
      {chipFamily && (
        <span
          className="acpmux-model-short acpmux-fit-label"
          data-fit-part="model"
          data-fit-forms="family"
          data-label={chipFamily}
        />
      )}
    </>
  );
  return (
    <span
      ref={root}
      className="acpmux-picker acpmux-model"
      style={{ position: "relative" }}
      // The controls row's harness mark alone names the model in a tooltip (composerRowFit.ts).
      {...(rowChip ? { "data-fit-title": chipTitle, "data-fit-title-unit": "model" } : {})}
    >
      {quick ? (
        // The compact menu's chip is its Base UI menu button (submenus need one); a press while
        // the full picker is open only closes it.
        <>
          <QuickModelMenu
            open={quickOpen}
            onOpenChange={(next) => {
              // A close is only ever the compact menu's own; a press on the chip while the full
              // picker is open closes that one instead.
              if (!next) setQuickOpen(false);
              else if (open) close();
              else setQuickOpen(true);
            }}
            trigger={trigger}
            chip={{
              "data-menu": modelText,
              label: modelText,
              /* tooltip-allow: the chip drops the vendor its mark draws; the title keeps the full name */
              title: [chipLabel, sessionAuthText, usage, updateText].filter(Boolean).join(" · "),
            }}
            menu={{
              ...quick,
              ...(props.sessionAuth
                ? {
                    auth: {
                      verdict: props.sessionAuth,
                      onLogin: props.onSessionLogin,
                      onRefresh: props.onSessionAuthRefresh,
                    },
                  }
                : {}),
              ...(update && updateText ? { update: { text: updateText, run: update.update } } : {}),
              // This harness's top models, the running one among them; a signed-out harness lists none.
              models:
                current && loginFor(current) === undefined
                  ? quickSections(current, props.model, (model) => !model.unavailable).shown.map((model) =>
                      quickRow("", model),
                    )
                  : [],
              current: props.model,
              onModel: (id) => {
                quickPicked.current = true;
                onLand(id);
              },
              search: { find: quickSearch, pick: pickQuickToPrompt },
              ...(quickFamilies
                ? {
                    families: {
                      list: quickFamilies,
                      current: current?.id,
                      onPick: pickQuickToPrompt,
                      ...(onAddAgent ? { onAddHarness: onAddAgent } : {}),
                      ...(harnessFixed ? {} : onHarness ? { onLaunch: pickProfile } : {}),
                      ...(harnessFixed && fork
                        ? { onLaunch: pickProfile, onFork: pickProfile, forkReady: fork.ready }
                        : {}),
                    },
                  }
                : {}),
            }}
            onMore={more}
          >
            {chipFace}
            {/* A quiet label, as Claude Code's: the model, then its effort, and no chevron. */}
            {detail && (
              <span
                className="acpmux-model-detail"
                data-fit-part="effort"
                data-fit-forms={detailShort ? "full" : "full short"}
              >
                {detail}
              </span>
            )}
            {detail && detailShort && (
              <span
                className="acpmux-model-detail acpmux-fit-label"
                data-fit-part="effort"
                data-fit-forms="short"
                data-label={detailShort}
              />
            )}
          </QuickModelMenu>
        </>
      ) : (
        <>
          <PickerButton
            ref={trigger}
            type="button"
            className="acpmux-picker-button"
            data-menu={modelText}
            aria-label={modelText}
            /* tooltip-allow: the chip drops the vendor its mark draws; the title keeps the full name */
            title={[chipLabel, sessionAuthText, usage, updateText].filter(Boolean).join(" · ")}
            aria-haspopup="dialog"
            aria-expanded={open}
            aria-controls={open ? menuId : undefined}
            keyboard={(event) => {
              if (open && event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
                event.preventDefault();
                setQuery(event.key);
                setActive(0);
                setAddChosen(false);
                search.current?.focus();
              } else if (!open && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
                event.preventDefault();
                show();
              }
            }}
            {...press}
          >
            {chipFace}
            <ChevronIcon />
          </PickerButton>
        </>
      )}
      {open && (
        <PickerDialog
          ref={menu}
          id={menuId}
          className="ui-popup ui-glass ui-picker-popup acpmux-mp z-(--layer-dropdown) flex w-[min(310px,var(--available-width,calc(100vw-24px)))] overflow-hidden rounded-[var(--ui-popup-radius,8px)] text-control text-fg"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the popover is positioned by the shared anchor helper.
          aria-label={modelText}
          // The anchor's room above or below the chip, between the picker's minimum and maximum
          // heights; a fixed height here collapsed a menu that opened before its models loaded.
          style={{ ...menuStyle, ...pickerHeightBounds(menuStyle.maxHeight, openHeight) }}
        >
          {/* The rail: Starred, then one icon per harness; a click or arrow key shows its models. A
              started chat's harness is fixed, so its menu has none. */}
          {!harnessFixed && (
            <ScrollArea
              className="acpmux-mp-rail-scroll w-11 flex-none border-r-[0.5px] border-edge"
              viewportClassName="acpmux-mp-rail-viewport"
              horizontal
            >
              <PickerOptionList
                className="acpmux-mp-rail-list flex flex-col items-center gap-1 py-1.5"
                aria-label={harnessText}
              >
                <PickerOption
                  type="button"
                  className={railTab}
                  aria-label={starredText}
                  title={starredText}
                  aria-selected={starredView}
                  selected={starredView}
                  active={starredView}
                  keyboard={(event) => {
                    if (!railHarnesses.length) return;
                    if (event.key === "ArrowDown") {
                      event.preventDefault();
                      moveRail(-1, 1);
                    } else if (event.key === "ArrowUp") {
                      event.preventDefault();
                      moveRail(-1, -1);
                    } else if (event.key === "ArrowRight" || event.key === "Enter") {
                      event.preventDefault();
                      search.current?.focus();
                    }
                  }}
                  onClick={() => showTab(STARRED, -1, true)}
                >
                  <StarGlyph filled={false} size={15} />
                </PickerOption>
                {railHarnesses.map((entry, index) => [
                  <PickerOption
                    type="button"
                    key={entry.folder ? `folder:${entry.id}` : entry.name}
                    aria-selected={entry.ids.includes(selectedHarness ?? "")}
                    aria-disabled={blockedProfile(entry) || loginFor(entry) !== undefined || undefined}
                    data-signed-out={loginFor(entry) !== undefined || undefined}
                    disabled={!entry.pickable}
                    data-harness-index={index}
                    className={`acpmux-mp-harness ${railTab}`}
                    title={railTitle(entry)}
                    selected={entry.ids.includes(selectedHarness ?? "")}
                    keyboard={(event) => {
                      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                        event.preventDefault();
                        const step = event.key === "ArrowDown" ? 1 : -1;
                        moveRail(index, step);
                      } else if (event.key === "Enter" && enableProfile(entry)) {
                        event.preventDefault();
                      } else if (event.key === "ArrowRight" || event.key === "Enter") {
                        event.preventDefault();
                        search.current?.focus();
                      }
                    }}
                    // Hover only warms the harness; its models show on a click or an arrow key
                    // (Leo 2026-10-11: a list that swaps under the pointer picks the wrong row).
                    onPointerEnter={() => onHarnessHint?.(entry.acpmuxHarness ?? entry.id)}
                    onClick={() => {
                      if (enableProfile(entry)) return;
                      showTab(entry.id, index, true);
                    }}
                    active={index === activeHarness}
                  >
                    {hasAgentMark(entry.mark ?? entry.id) ? (
                      <AgentMark agent={entry.mark ?? entry.id} size={16} />
                    ) : (
                      // A harness without a mark: its initial, never an empty tab.
                      <span aria-hidden="true" className="text-control font-semibold">
                        {entry.name.trim().charAt(0).toUpperCase()}
                      </span>
                    )}
                    <span className="sr-only">{entry.name}</span>
                  </PickerOption>,
                ])}
              </PickerOptionList>
            </ScrollArea>
          )}
          <div className="acpmux-mp-content flex min-w-0 flex-1 flex-col">
            {sessionAuthText && (
              <output className="acpmux-mp-auth flex flex-none items-center gap-2 border-b-[0.5px] border-edge px-3 py-2 text-detail text-muted">
                <span className="min-w-0 flex-1">{sessionAuthText}</span>
                {canSessionLogin(props.sessionAuth) && props.onSessionLogin && (
                  <button type="button" className="acpmux-mp-auth-action" onClick={() => props.onSessionLogin?.()}>
                    {t("harness.logIn")}
                  </button>
                )}
                {props.onSessionAuthRefresh && (
                  <button type="button" className="acpmux-mp-auth-action" onClick={props.onSessionAuthRefresh}>
                    {t("harnesses.checkAgain")}
                  </button>
                )}
              </output>
            )}
            <div className="acpmux-mp-search flex h-[var(--ui-row-height,28px)] flex-none items-center gap-2 border-b-[0.5px] border-edge px-2 text-muted focus-within:text-fg">
              <SearchIcon size={15} />
              <PickerComboboxInput
                ref={search}
                type="search"
                // The picker opens with focus here; its row shows the focus, not a ring inside it.
                data-focus-ring="none"
                className="h-full min-w-0 flex-1 appearance-none border-0 bg-transparent p-0 font-[inherit] text-body text-fg outline-none placeholder:text-muted [&::-webkit-search-cancel-button]:appearance-none"
                aria-label={searchText}
                aria-autocomplete="list"
                aria-controls={`${menuId}-models`}
                aria-activedescendant={activeRowId}
                aria-expanded="true"
                value={query}
                placeholder={searchText}
                onChange={(event) => {
                  setQuery(event.target.value);
                  setActive(0);
                  setAddChosen(false);
                }}
                keyboard={keyDown}
              />
              {catalogRefresh && (
                <button
                  type="button"
                  className="grid size-7 flex-none cursor-pointer place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg disabled:cursor-default"
                  data-refresh-status={refreshStatus}
                  aria-label={t("picker.refreshCatalog")}
                  title={refreshTitle}
                  disabled={refreshStatus === "fetching"}
                  onClick={refreshCatalog}
                >
                  {refreshStatus === "fetching" ? (
                    <span className="acpmux-mp-refresh-spinner" aria-hidden="true" />
                  ) : (
                    <Icon name="action.reload" size={14} />
                  )}
                </button>
              )}
            </div>
            <ScrollArea className="min-h-0 flex-1">
              <PickerOptionList
                id={`${menuId}-models`}
                className="acpmux-mp-models"
                aria-label={searching ? searchText : starredView ? starredText : (selected?.name ?? modelText)}
              >
                {!searching && !starredView && folderProfiles.length > 0 && (
                  <div className="acpmux-mp-folder-profiles mb-1 border-b-[0.5px] border-edge pb-1">
                    <div className="px-2 py-1 text-detail text-muted">{t("picker.thisFolder")}</div>
                    {folderProfiles.map((entry) => (
                      <button
                        type="button"
                        key={`folder-profile:${entry.id}`}
                        className={`acpmux-mp-row ${modelRow} ${rowFill(selectedHarness === entry.id)}`}
                        onClick={() => {
                          setSelectedHarness(entry.id);
                          setOlderOpen(false);
                          setActive(0);
                          setAddChosen(false);
                        }}
                      >
                        <span className="acpmux-menu-label flex-1 truncate">{entry.name}</span>
                        {folderNote(entry) && <span className="acpmux-quick-value">{folderNote(entry)}</span>}
                      </button>
                    ))}
                  </div>
                )}
                {selected && !searching && !starredView && loginFor(selected) !== undefined ? (
                  <>
                    <div className={emptyNote}>{t("harness.signedOut", { agent: selected.name })}</div>
                    {loginFor(selected) && onLogIn && (
                      <button
                        type="button"
                        className={`acpmux-mp-row acpmux-mp-login ${modelRow} ${rowFill(false)}`}
                        onClick={() => {
                          onLogIn(selected.acpmuxHarness ?? selected.id, loginFor(selected)!);
                          close();
                        }}
                      >
                        <span className="acpmux-menu-label flex-1 truncate">{t("harness.logIn")}</span>
                      </button>
                    )}
                  </>
                ) : selectedOther && blockedProfile(selected) ? (
                  <div className={emptyNote}>
                    {selected.folder?.state === "needs-trust"
                      ? t("picker.trustFirst")
                      : (selected.folder?.diagnostic ?? unavailableText)}
                  </div>
                ) : selectedOther && selected.folder?.state === "needs-enable" ? (
                  <button
                    type="button"
                    className={`acpmux-mp-row ${modelRow} ${rowFill(false)}`}
                    onClick={() => enableProfile(selected)}
                  >
                    <span className="acpmux-menu-label flex-1 truncate">{t("harness.enable")}</span>
                  </button>
                ) : selectedOther && selected.folder && visible.length === 0 && !query ? (
                  <button
                    type="button"
                    className={`acpmux-mp-row ${modelRow} ${rowFill(false)}`}
                    onClick={() => {
                      onHarness?.(selected.id);
                      close();
                    }}
                  >
                    <span className="acpmux-menu-label flex-1 truncate">{t("picker.newChat")}</span>
                  </button>
                ) : visible.length === 0 ? (
                  <div className={emptyNote}>
                    {starredView && !query
                      ? t("picker.starredEmpty")
                      : !query && selected && selected.models.length === 0
                        ? t("picker.noModels")
                        : noMatchesText}
                  </div>
                ) : (
                  visible.map((model, index) => (
                    <div className="group relative flex items-center" key={`${owners.get(model)?.id}:${model.id}`}>
                      <PickerOption
                        type="button"
                        id={modelRowId(model.id)}
                        data-key={`model:${model.id}`}
                        selected={index === active}
                        aria-checked={model.id === props.model && owners.get(model)?.ids.includes(harness ?? "")}
                        className={`acpmux-mp-row ${modelRow} ${rowFill(index === active)} ${model.id === props.model ? "pr-14" : "pr-8"}${index === active ? " acpmux-mp-active" : ""}`}
                        onPointerEnter={() => setActive(index)}
                        disabled={Boolean(model.unavailable)}
                        onClick={() => selectModel(model)}
                        active={index === active}
                      >
                        {(starredView || searching) && (
                          <AgentMark agent={owners.get(model)?.mark ?? owners.get(model)?.id} size={14} reserve />
                        )}
                        <span className="acpmux-menu-label min-w-0 flex-1 truncate">{model.name}</span>
                        {searching && (parsed.effort || parsed.fast) && (
                          <span className="acpmux-mp-combo flex-none text-detail text-dim">
                            {[modelEffort(model, parsed.effort), parsed.fast ? fastText : undefined]
                              .filter(Boolean)
                              .join(" · ")}
                          </span>
                        )}
                        {model.unavailable && <span className="flex-none text-detail text-dim">{unavailableText}</span>}
                      </PickerOption>
                      <span className="pointer-events-none absolute right-1.5 flex items-center">
                        <button
                          type="button"
                          className={`acpmux-mp-favorite pointer-events-auto grid size-6 cursor-pointer place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:text-fg ${favorites.has(model.id) ? "" : "invisible group-hover:visible focus-visible:visible"}`}
                          aria-label={`${starredText}: ${model.name}`}
                          aria-pressed={favorites.has(model.id)}
                          title={t(favorites.has(model.id) ? "picker.unstar" : "picker.star")}
                          onClick={() => toggleFavorite(model.id)}
                        >
                          <StarGlyph filled={favorites.has(model.id)} size={13} />
                        </button>
                        {model.id === props.model && owners.get(model)?.ids.includes(harness ?? "") && (
                          <span className="grid size-6 place-items-center text-muted">
                            <CheckIcon />
                          </span>
                        )}
                      </span>
                    </div>
                  ))
                )}
                {olderCount > 0 && !(selectedOther && selected?.folder && visible.length === 0) && (
                  <button
                    type="button"
                    className={`acpmux-mp-older ${modelRow} ${rowFill(false)} text-muted`}
                    aria-expanded={olderOpen}
                    onClick={() => setOlderOpen((value) => !value)}
                  >
                    <span className="acpmux-menu-label min-w-0 flex-1 truncate">{t("picker.moreModels")}</span>
                    <span className="flex-none text-detail text-dim">{olderCount}</span>
                    <span className={`flex-none ${olderOpen ? "rotate-180" : ""}`} aria-hidden="true">
                      <ChevronIcon />
                    </span>
                  </button>
                )}
                {onAddAgent && (
                  // Add harness… (Leo 2026-10-14): the list's last row; it opens the Harnesses page.
                  <>
                    <hr className="mx-2 my-1 h-0 border-0 border-t-[0.5px] border-edge" />
                    <PickerOption
                      type="button"
                      id={addRowId}
                      className={`acpmux-mp-add-harness acpmux-mp-row ${modelRow} ${rowFill(onAddRow)}${onAddRow ? " acpmux-mp-active" : ""}`}
                      onPointerEnter={() => {
                        setActive(addRow);
                        setAddChosen(true);
                      }}
                      onClick={addHarness}
                      selected={onAddRow}
                      active={onAddRow}
                    >
                      <span className="acpmux-menu-label min-w-0 flex-1 truncate">{addHarnessText}</span>
                    </PickerOption>
                  </>
                )}
              </PickerOptionList>
            </ScrollArea>
            {update && (
              <div className="acpmux-mp-update flex flex-none items-center gap-1 border-t-[0.5px] border-edge p-1.5 pl-2.5">
                <span className="min-w-0 flex-1 truncate text-detail text-muted">{updateText}</span>
                <button
                  type="button"
                  className={`acpmux-mp-update-run ${updateButton} ${rowFill(false)}`}
                  onClick={() => {
                    update.update();
                    close();
                  }}
                >
                  {t("harness.update")}
                </button>
                <button
                  type="button"
                  className={`acpmux-mp-update-skip ${updateButton} ${rowFill(false)}`}
                  onClick={update.skip}
                >
                  {t("harness.skipVersion")}
                </button>
              </div>
            )}
            {fastMode && (
              <div className="flex-none border-t-[0.5px] border-edge p-1.5">
                <button
                  type="button"
                  className={`acpmux-mp-fast ${modelRow} ${rowFill(false)} justify-between`}
                  aria-pressed={fastModeIsOn(fastMode)}
                  onClick={() => fastMode.onPick(nextFastModeValue(fastMode, fastMode.lastOnValue, fastMode.values))}
                >
                  <span>{fastMode.name}</span>
                  <span className="text-detail text-dim">
                    {fastModeIsOn(fastMode) ? fastMode.onLabel : fastMode.offLabel}
                  </span>
                </button>
              </div>
            )}
          </div>
        </PickerDialog>
      )}
    </span>
  );
}

/** A model name as the chip shows it, without the vendor its mark already draws ("Claude Opus 5.5"
 * under Claude's mark reads "Opus 5.5"; Leo 2026-10-13: the footer "tells too much"). Only Claude's
 * names lead with a vendor word that says nothing else ("Gemini 2.5 Pro" would read as a bare
 * number), and another harness's mark (a gateway's) does not say the vendor. The title keeps the
 * full name. */
export function withoutVendor(name: string, mark?: string): string {
  if (!mark?.toLowerCase().startsWith("claude")) return name;
  return name.replace(/^Claude\s+(?=\S)/, "");
}
