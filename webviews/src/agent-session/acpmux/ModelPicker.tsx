import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import { AgentMark, agentBrand, knownMark } from "../shared/AgentMark";
import { agentName } from "./agents";
import { isDefaultChoice } from "./defaultChoice";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { Icon } from "./icons/Icon";
import { currentLanguage, useT } from "./i18n";
import { MODEL_PICKER_MAX_HEIGHT, type ModelPickerProps } from "./modelPickerLayout";
import { modelSections } from "./modelSections";
import { effortWords, fitsQuery, modelEffort, parseQuery } from "./modelQuery";
import { registerPicker } from "./pickerOpeners";
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
};

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

/// With a curated list: its models first, in its order, each followed by its variants ("Fable 5.1 ·
/// 1M context"), and every other model under More models, newest family first, then older ones. Without one, or when
/// the harness offers none of it, the catalog's newest family stays first.
function curatedSections(
  sections: { latest: ModelChoice[]; older: ModelChoice[] },
  top: readonly string[] | undefined,
): { latest: ModelChoice[]; older: ModelChoice[] } {
  if (!top) return sections;
  const all = [...sections.latest, ...sections.older];
  const latest: ModelChoice[] = [];
  for (const id of top) {
    const model = all.find((choice) => choice.id === id || choice.release === id);
    if (!model) continue;
    const variants = all.filter(
      (choice) => choice !== model && (choice.id.startsWith(`${id}[`) || choice.name.startsWith(`${model.name} · `)),
    );
    for (const choice of [model, ...variants]) if (!latest.includes(choice)) latest.push(choice);
  }
  if (latest.length === 0) return sections;
  return { latest, older: all.filter((choice) => !latest.includes(choice)) };
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

/// The rail's Starred tab (never a harness id).
const STARRED = "\u0000starred";

/// A folder profile row the user cannot start yet: waiting for the folder's Trust answer, or broken.
const blockedProfile = (entry: HarnessChoice | undefined) =>
  entry?.folder?.state === "needs-trust" || entry?.folder?.state === "error";

/// A rail tab: one icon in a rounded square, filled while its models show.
const railTab =
  "acpmux-mp-rail-tab grid size-8 flex-none cursor-pointer place-items-center rounded-[var(--ui-row-radius,5px)] border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg aria-selected:bg-hover aria-selected:text-fg disabled:cursor-default disabled:opacity-50 aria-disabled:opacity-50";
/// A model row: one line, the theme's text. The fill is separate (`rowFill`): two background
/// utilities on one element resolve by Tailwind's output order, not by the class list.
const modelRow =
  "flex h-[var(--ui-row-height,28px)] w-full cursor-pointer items-center gap-2 rounded-[var(--ui-row-radius,5px)] border-0 px-2 text-left font-[inherit] text-control text-fg disabled:cursor-default disabled:opacity-50";
/// The active row (pointer or arrows) has the hover wash; any other row gets it on hover.
const rowFill = (active: boolean) => (active ? "bg-hover" : "bg-transparent hover:bg-hover");
const emptyNote = "px-2.5 py-2 text-body text-muted";

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
    switching,
    onLand,
    onHarness,
    onHarnessHint,
    onHarnessEnable,
    onAddAgent,
    onCombo,
    fastMode,
    catalogRefresh,
  } = props;
  const t = useT();
  const modelText = t(PICKER_LABELS.model);
  const searchText = t("picker.search");
  const harnessText = t("picker.harness");
  const noMatchesText = t("picker.noMatches");
  const starredText = t("picker.starred");
  const addAgentText = t("picker.addAgent");
  const fastText = t("picker.fastOn");
  const unavailableText = t("picker.unavailable");
  const modelRowId = (id: string) => `${menuId}-model-${encodeURIComponent(id)}`;
  const [open, setOpen] = useState(false);
  const [openHeight, setOpenHeight] = useState<number>();
  const [selectedHarness, setSelectedHarness] = useState(harness);
  const [activeHarness, setActiveHarness] = useState(0);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
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
  const menuId = useId();
  const harnesses = useMemo(() => uniqueHarnesses(catalog), [catalog]);
  const navigableHarnesses = useMemo(
    () =>
      harnesses
        .map((entry, index) => ({ entry, index }))
        .filter(({ entry }) => entry.pickable && !blockedProfile(entry)),
    [harnesses],
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
      for (const entry of harnesses)
        if (entry.pickable && !blockedProfile(entry))
          for (const model of choicesFor(entry)) if (fitsQuery(model, entry.name, parsed)) owner.set(model, entry);
    } else if (starredView) {
      for (const entry of harnesses)
        for (const model of choicesFor(entry)) if (favorites.has(model.id)) owner.set(model, entry);
    } else if (selected) {
      // Every model past the top ones folds under More models until it opens (cx-jqkx, cx-espus).
      const { latest, older } = shownSections(selected, runsHere);
      for (const model of olderOpen ? [...latest, ...older] : latest) owner.set(model, selected);
    }
    return owner;
  }, [favorites, harnesses, olderOpen, parsed, searching, selected, starredView, runsHere]);
  const visible = useMemo(() => [...owners.keys()], [owners]);
  const olderCount = searching || starredView ? 0 : shownSections(selected, runsHere).older.length;
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
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  useLayoutEffect(() => {
    if (!open) {
      setOpenHeight(undefined);
      return;
    }
    if (menuStyle.visibility !== "visible" || openHeight != null) return;
    const node = menu.current;
    if (node) setOpenHeight(Math.ceil(node.getBoundingClientRect().height));
  }, [menuStyle.visibility, open, openHeight]);
  const close = useCallback(
    (focus = true) => {
      restoreFocus.current = focus;
      setOpen(false);
      onHarnessHint?.(undefined);
    },
    [onHarnessHint],
  );
  useEffect(() => {
    if (open || !restoreFocus.current) return;
    restoreFocus.current = false;
    // A pointerup can still apply its default focus after React closes the popup. Defer the
    // restoration until that browser action has finished. A second frame also covers the
    // narrow drill's late focus handoff, matching the popup's final focus contract for
    // press-drag-release selection.
    let second: number | undefined;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => trigger.current?.focus({ preventScroll: true }));
    });
    return () => {
      cancelAnimationFrame(first);
      if (second !== undefined) cancelAnimationFrame(second);
    };
  }, [open]);
  const show = useCallback(() => {
    setSelectedHarness(harness ?? current?.id);
    setActiveHarness(
      Math.max(
        0,
        harnesses.findIndex((entry) => entry.ids.includes(harness ?? "")),
      ),
    );
    setQuery("");
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
  }, [current, harness, harnesses, open, props.model]);
  const showRef = useRef(show);
  showRef.current = show;
  const toggle = open ? (_next: boolean) => close() : setOpen;
  const press = usePopoverTrigger(open, toggle, show);
  useEscapeCloses(open, close);

  useLayoutEffect(() => {
    // The anchor's first render is hidden while it measures. Browsers cannot focus search
    // until the positioned menu is visible, even though JSDOM accepts that early focus.
    if (open && menuStyle.visibility === "visible") search.current?.focus({ preventScroll: true });
  }, [open, menuStyle.visibility]);
  // The highlighted row stays in view (Lawrence 2026-10-09 recording: ArrowDown moved the highlight below the
  // visible rows and the list did not follow). The nearest scroll only moves when the row is outside the list's
  // viewport, so a pointer hover (always over a visible row) never scrolls.
  const activeRowId = visible[active] ? modelRowId(visible[active].id) : undefined;
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
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [close, open]);
  useEffect(() => registerPicker(modelText, () => showRef.current()), [modelText]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      // Cmd-Ctrl-M opens the picker (Lawrence 2026-10-08); typing then searches every harness.
      if (event.metaKey && event.ctrlKey && !event.altKey && event.key.toLowerCase() === "m") {
        event.preventDefault();
        showRef.current();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
  useEffect(() => {
    if (!open) setSelectedHarness(harness);
  }, [harness, open]);
  useEffect(() => {
    if (active >= visible.length) setActive(Math.max(visible.length - 1, 0));
  }, [active, visible.length]);

  const selectModel = (model: ModelChoice) => {
    const owner = owners.get(model);
    if (model.unavailable || !owner?.pickable) return;
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
      showTab(harnesses[next]?.id, next);
      focusRail(next);
    }
  };
  const move = (step: number) => {
    // Moving down past the last row opens the More models fold, so keys reach every model.
    if (step > 0 && !olderOpen && olderCount > 0 && active >= visible.length - 1) {
      setOlderOpen(true);
      setActive(visible.length);
      return;
    }
    setActive((index) => (visible.length ? (index + step + visible.length) % visible.length : 0));
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
    } else if (event.key === "ArrowLeft" && !query) {
      event.preventDefault();
      if (starredView) focusRail(-1);
      else focusRail(activeHarness);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const model = visible[active];
      if (model) selectModel(model);
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
  const firstProfile = harnesses.findIndex((entry) => entry.folder);
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
    return [shared ? `${entry.name} (${entry.id})` : entry.name, folderNote(entry)].filter(Boolean).join(" · ");
  };
  return (
    <span ref={root} className="acpmux-picker acpmux-model" style={{ position: "relative" }}>
      <PickerButton
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        data-menu={modelText}
        aria-label={modelText}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        keyboard={(event) => {
          if (open && event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
            event.preventDefault();
            setQuery(event.key);
            setActive(0);
            search.current?.focus();
          } else if (!open && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
            event.preventDefault();
            show();
          }
        }}
        {...press}
      >
        <AgentMark agent={chipHarness} size={15} />
        <span className="acpmux-model-name">{chipLabel}</span>
        <ChevronIcon />
      </PickerButton>
      {open && (
        <PickerDialog
          ref={menu}
          id={menuId}
          className="ui-popup ui-picker-popup acpmux-mp z-[3] flex max-h-[480px] w-[min(310px,calc(100vw-24px))] overflow-hidden rounded-[var(--ui-popup-radius,8px)] text-control text-fg"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the popover is positioned by the shared anchor helper.
          aria-label={modelText}
          // The anchor's room above or below the chip, never more than MODEL_PICKER_MAX_HEIGHT.
          style={{
            ...menuStyle,
            maxHeight: Math.min(
              typeof menuStyle.maxHeight === "number" ? menuStyle.maxHeight : MODEL_PICKER_MAX_HEIGHT,
              MODEL_PICKER_MAX_HEIGHT,
            ),
            ...(openHeight == null ? {} : { height: openHeight }),
          }}
        >
          {/* The rail: Starred, then one icon per harness; a click or arrow key shows its models. */}
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
                  if (!harnesses.length) return;
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
              {harnesses.map((entry, index) => [
                index === firstProfile && (
                  <hr
                    key="folder-section"
                    className="my-0.5 h-0 w-5 flex-none border-0 border-t-[0.5px] border-edge"
                    aria-label={t("picker.thisFolder")}
                  />
                ),
                <PickerOption
                  type="button"
                  key={entry.folder ? `folder:${entry.id}` : entry.name}
                  aria-selected={entry.ids.includes(selectedHarness ?? "")}
                  aria-disabled={blockedProfile(entry) || undefined}
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
                  {agentBrand(entry.mark ?? entry.id) ? (
                    <AgentMark agent={entry.mark ?? entry.id} size={16} />
                  ) : (
                    // A harness without a mark: its initial, never an empty tab.
                    <span aria-hidden="true" className="text-control font-medium">
                      {entry.name.trim().charAt(0).toUpperCase()}
                    </span>
                  )}
                  <span className="sr-only">{entry.name}</span>
                </PickerOption>,
              ])}
              {onAddAgent && (
                // Add agent… (BRING-YOUR-OWN-HARNESS): Settings > Agents > Add. Not a tab: a click runs it.
                <button
                  type="button"
                  className={`acpmux-mp-add-agent mt-auto ${railTab}`}
                  aria-label={addAgentText}
                  title={addAgentText}
                  onClick={() => {
                    close();
                    onAddAgent();
                  }}
                >
                  <span aria-hidden="true" className="text-heading leading-none">
                    +
                  </span>
                </button>
              )}
            </PickerOptionList>
          </ScrollArea>
          <div className="acpmux-mp-content flex min-w-0 flex-1 flex-col">
            <div className="acpmux-mp-search flex h-9 flex-none items-center gap-2 border-b-[0.5px] border-edge pr-1.5 pl-3 text-muted focus-within:text-fg">
              <SearchIcon size={15} />
              <PickerComboboxInput
                ref={search}
                type="search"
                // The picker opens with focus here; its row shows the focus, not a ring inside it.
                data-focus-ring="none"
                className="h-full min-w-0 flex-1 appearance-none border-0 bg-transparent p-0 font-[inherit] text-fg outline-none placeholder:text-muted [&::-webkit-search-cancel-button]:appearance-none"
                aria-label={searchText}
                aria-autocomplete="list"
                aria-controls={`${menuId}-models`}
                aria-activedescendant={visible[active] ? modelRowId(visible[active].id) : undefined}
                aria-expanded="true"
                value={query}
                placeholder={searchText}
                onChange={(event) => {
                  setQuery(event.target.value);
                  setActive(0);
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
                className="acpmux-mp-models p-1.5"
                aria-label={searching ? searchText : starredView ? starredText : (selected?.name ?? modelText)}
              >
                {selectedOther && blockedProfile(selected) ? (
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
                          title={starredText}
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
              </PickerOptionList>
            </ScrollArea>
            {fastMode && (
              <div className="flex-none border-t-[0.5px] border-edge p-1.5">
                <button
                  type="button"
                  className={`acpmux-mp-fast ${modelRow} ${rowFill(false)} justify-between`}
                  aria-pressed={fastMode.currentValue === fastMode.onValue}
                  onClick={() =>
                    fastMode.onPick(fastMode.currentValue === fastMode.onValue ? fastMode.offValue : fastMode.onValue)
                  }
                >
                  <span>{fastMode.name}</span>
                  <span className="text-detail text-dim">
                    {fastMode.currentValue === fastMode.onValue ? fastMode.onLabel : fastMode.offLabel}
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
