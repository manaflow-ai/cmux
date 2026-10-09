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
import { createPortal } from "react-dom";
import { usePortalContainer } from "../../ui/UiProvider";
import { ModelPickerRefresh } from "./ModelPickerRefresh";
import { favoriteKey, loadFavorites, saveFavorites } from "./modelFavorites";
import { AgentMark } from "../shared/AgentMark";
import { agentName } from "./agents";
import { isDefaultChoice } from "./defaultChoice";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import type { ModelPickerProps } from "./modelPickerLayout";
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
  }[];
  unavailable?: string;
  acpmuxHarness?: string;
  pickable: boolean;
  /** A profile from the chat's folder and its state. */
  folder?: ModelPickerProps["catalog"][number]["folder"];
  /** The brand the row's mark draws (a folder profile's icon or family, else its id). */
  mark?: string;
};

type ModelChoice = {
  id: string;
  name: string;
  family?: string;
  unavailable?: string;
  efforts?: string[];
  fast?: boolean;
};

/// A harness's models, each once, newest first: the default and each family's newest models
/// (`latest`), then every older version (`older`, folded in the list). A catalog model names
/// itself by its short name under its harness ("Opus 5.5"). Choices are memoized per harness
/// entry, so the owner map keys stay the same objects between renders.
const choiceCache = new WeakMap<HarnessChoice, { latest: ModelChoice[]; older: ModelChoice[] }>();
function sectionsFor(entry: HarnessChoice | undefined): { latest: ModelChoice[]; older: ModelChoice[] } {
  if (!entry) return { latest: [], older: [] };
  const cached = choiceCache.get(entry);
  if (cached) return cached;
  const seen = new Set<string>();
  const choices = entry.models.flatMap((model): ModelChoice[] => {
    if (seen.has(model.id)) return [];
    seen.add(model.id);
    return [
      {
        id: model.id,
        name: isDefaultChoice(model) ? "Default" : model.shortName || model.name || model.id,
        ...(model.family ? { family: model.family } : {}),
        unavailable: model.unavailable,
        efforts: model.efforts,
        fast: model.fast,
      },
    ];
  });
  const sections = modelSections(choices, entry.name);
  choiceCache.set(entry, sections);
  return sections;
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
      mark: entry.icon ?? entry.family ?? entry.id,
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
  "grid size-9 flex-none cursor-pointer place-items-center rounded-lg border-0 bg-transparent p-0 text-muted hover:bg-hover hover:text-fg aria-selected:bg-hover aria-selected:text-fg disabled:cursor-default disabled:opacity-50 aria-disabled:opacity-50";
/// A model row: a generous, readable identity row with the theme's text. The fill is separate (`rowFill`): two background
/// utilities on one element resolve by Tailwind's output order, not by the class list.
const modelRow =
  "flex min-h-10 w-full cursor-pointer items-center gap-2 rounded-lg border-0 px-3 py-2 text-left font-[inherit] text-control text-fg disabled:cursor-default disabled:opacity-50";
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
  const modelRowId = (choice: ModelChoice) =>
    `${menuId}-model-${encodeURIComponent(favoriteKey(owners.get(choice)?.id ?? "", choice.id))}`;
  const [open, setOpen] = useState(false);
  const [selectedHarness, setSelectedHarness] = useState(harness);
  const [activeHarness, setActiveHarness] = useState(0);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const [olderOpen, setOlderOpen] = useState(false);
  const [favorites, setFavorites] = useState(() => loadFavorites(uniqueHarnesses(catalog)));
  const portalContainer = usePortalContainer();
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();
  const harnesses = useMemo(() => uniqueHarnesses(catalog), [catalog]);
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
  const owners = useMemo(() => {
    const owner = new Map<ModelChoice, HarnessChoice>();
    if (searching) {
      for (const entry of harnesses)
        if (entry.pickable && !blockedProfile(entry))
          for (const model of choicesFor(entry)) if (fitsQuery(model, entry.name, parsed)) owner.set(model, entry);
    } else if (starredView) {
      for (const entry of [...harnesses].sort((a, b) => a.name.localeCompare(b.name)))
        for (const model of choicesFor(entry).sort((a, b) => a.name.localeCompare(b.name)))
          if (favorites.has(favoriteKey(entry.id, model.id))) owner.set(model, entry);
    } else if (selected) {
      // Older versions fold under one row until it opens (cx-jqkx).
      const { latest, older } = sectionsFor(selected);
      for (const model of olderOpen ? [...latest, ...older] : latest) owner.set(model, selected);
    }
    return owner;
  }, [favorites, harnesses, olderOpen, parsed, searching, selected, starredView]);
  const visible = useMemo(() => [...owners.keys()], [owners]);
  const olderCount = searching || starredView ? 0 : sectionsFor(selected).older.length;
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  const close = useCallback(
    (focus = true) => {
      setOpen(false);
      onHarnessHint?.(undefined);
      if (focus) trigger.current?.focus();
    },
    [onHarnessHint],
  );
  const show = useCallback(() => {
    setSelectedHarness(harness ?? current?.id);
    setActiveHarness(
      Math.max(
        0,
        harnesses.findIndex((entry) => entry.ids.includes(harness ?? "")),
      ),
    );
    setQuery("");
    // A session on an older version opens with the fold open, its row highlighted.
    const { latest, older } = sectionsFor(current);
    const runsOlder = older.some((model) => model.id === props.model);
    setOlderOpen(runsOlder);
    setActive(
      Math.max(
        0,
        (runsOlder ? [...latest, ...older] : latest).findIndex((model) => model.id === props.model),
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
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node) && !menu.current?.contains(event.target as Node)) close(false);
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
  const toggleFavorite = (choice: ModelChoice) => {
    const owner = owners.get(choice);
    if (!owner) return;
    const key = favoriteKey(owner.id, choice.id);
    setFavorites((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      saveFavorites(next);
      return next;
    });
  };
  /// Shows a rail tab's models (hover or click); the typed query stays.
  const showTab = (id: string | undefined, index: number, clear = false) => {
    if (clear && query) setQuery("");
    else if (searching) return;
    if (id === undefined || id === selectedHarness) return;
    setSelectedHarness(id);
    setOlderOpen(false);
    setActiveHarness(index);
    setActive(0);
  };
  const move = (step: number) => {
    // Moving down past the last row opens the "Older models" fold, so keys reach every model.
    if (step > 0 && !olderOpen && olderCount > 0 && active >= visible.length - 1) {
      setOlderOpen(true);
      setActive(visible.length);
      return;
    }
    setActive((index) => (visible.length ? (index + step + visible.length) % visible.length : 0));
  };
  const keyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
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
      menu.current?.querySelectorAll<HTMLElement>("[data-rail-tab]")[activeHarness + 1]?.focus();
    } else if (event.key === "Enter") {
      event.preventDefault();
      const model = visible[active];
      if (model) selectModel(model);
    } else if (
      !query &&
      /^[1-9]$/.test(event.key) &&
      !event.ctrlKey &&
      !event.altKey &&
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
  const railKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>, index: number) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      const currentIndex = index + 1;
      const next = (currentIndex + step + harnesses.length + 1) % (harnesses.length + 1);
      showTab(next === 0 ? STARRED : harnesses[next - 1]?.id, next - 1, true);
      menu.current?.querySelectorAll<HTMLElement>("[data-rail-tab]")[next]?.focus();
    } else if (event.key === "ArrowRight" || event.key === "Enter") {
      event.preventDefault();
      search.current?.focus();
    }
  };
  useLayoutEffect(() => {
    if (!open) return;
    const list = menu.current?.querySelector<HTMLElement>(".acpmux-mp-models");
    const row = list?.querySelector<HTMLElement>('[aria-selected="true"]');
    if (!list || !row) return;
    const bounds = list.getBoundingClientRect();
    const item = row.getBoundingClientRect();
    if (item.top < bounds.top) list.scrollTop -= bounds.top - item.top;
    else if (item.bottom > bounds.bottom) list.scrollTop += item.bottom - bounds.bottom;
  }, [active, open, visible]);
  // The chip draws one harness: the one a switch to another harness is starting, else the running
  // one. Browsing another harness in the open menu changes neither its mark nor its name.
  const switchingTo = switching && !current?.ids.includes(switching.harness) ? switching : undefined;
  const chipHarness = switchingTo?.harness ?? current?.id ?? harness;
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
  return (
    <span ref={root} className="acpmux-picker acpmux-model" style={{ position: "relative" }}>
      <PickerButton
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        data-menu={modelText}
        aria-label={modelText}
        aria-busy={Boolean(switching)}
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
        {switching && <span className="acpmux-mp-refresh-spinner" aria-hidden="true" />}
        <span className="acpmux-model-name">{chipLabel}</span>
        <ChevronIcon />
      </PickerButton>
      {open &&
        createPortal(
          <PickerDialog
            ref={menu}
            id={menuId}
            className={`acpmux-mp flex h-[min(460px,75vh)] w-[min(380px,calc(100vw-24px))] overflow-hidden rounded-2xl bg-menu text-control text-fg shadow-menu z-(--layer-dropdown)`}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the popover is positioned by the shared anchor helper.
            aria-label={modelText}
            style={menuStyle}
          >
            {/* The rail: Starred, then one icon per harness; hovering a tab shows its models. */}
            <PickerOptionList
              className="flex w-14 flex-none flex-col items-center gap-2 overflow-y-auto border-r-[0.5px] border-edge bg-menu py-3"
              aria-label={harnessText}
            >
              <PickerOption
                type="button"
                className={railTab}
                data-rail-tab="starred"
                keyboard={(event) => railKeyDown(event, -1)}
                aria-label={starredText}
                title={starredText}
                aria-selected={starredView}
                selected={starredView}
                active={starredView}
                onPointerEnter={() => showTab(STARRED, -1)}
                onClick={() => showTab(STARRED, -1, true)}
              >
                <StarGlyph filled={false} size={17} />
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
                  data-rail-tab={entry.id}
                  aria-selected={entry.ids.includes(selectedHarness ?? "")}
                  aria-disabled={blockedProfile(entry) || undefined}
                  disabled={!entry.pickable}
                  className={`acpmux-mp-harness ${railTab}`}
                  title={[entry.name, folderNote(entry)].filter(Boolean).join(" · ")}
                  selected={entry.ids.includes(selectedHarness ?? "")}
                  keyboard={(event) => {
                    if (event.key === "Enter" && enableProfile(entry)) event.preventDefault();
                    else railKeyDown(event, index);
                  }}
                  onPointerEnter={() => {
                    onHarnessHint?.(entry.acpmuxHarness ?? entry.id);
                    if (entry.pickable) showTab(entry.id, index);
                  }}
                  onClick={() => {
                    if (enableProfile(entry)) return;
                    showTab(entry.id, index, true);
                  }}
                  active={index === activeHarness}
                >
                  <AgentMark agent={entry.mark ?? entry.id} size={18} />
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
            <div className="flex min-w-0 flex-1 flex-col">
              <div className="flex flex-none items-start justify-between gap-2 px-4 pt-4 pb-3">
                <div className="min-w-0">
                  <div className="text-title font-semibold">{starredView && !searching ? starredText : modelText}</div>
                  <div className="mt-1 text-detail text-muted">{t("picker.searchAllProviders")}</div>
                </div>
                <button
                  type="button"
                  className="grid size-6 flex-none place-items-center rounded-md border-0 bg-transparent text-muted hover:bg-hover hover:text-fg"
                  aria-label={t("chatMenu.close")}
                  onClick={() => close()}
                >
                  <span aria-hidden="true">×</span>
                </button>
              </div>
              <div className="acpmux-mp-search mx-3 mb-2 flex h-9 flex-none items-center gap-2 rounded-lg border border-solid border-edge bg-base px-2.5 text-muted focus-within:border-muted focus-within:text-fg">
                <SearchIcon size={15} />
                <PickerComboboxInput
                  ref={search}
                  type="search"
                  className="h-full min-w-0 flex-1 appearance-none border-0 bg-transparent p-0 font-[inherit] text-fg outline-none placeholder:text-muted [&::-webkit-search-cancel-button]:appearance-none"
                  aria-label={searchText}
                  aria-autocomplete="list"
                  aria-controls={`${menuId}-models`}
                  aria-activedescendant={visible[active] ? modelRowId(visible[active]) : undefined}
                  aria-expanded="true"
                  value={query}
                  placeholder={searchText}
                  onChange={(event) => {
                    setQuery(event.target.value);
                    setActive(0);
                  }}
                  keyboard={keyDown}
                />
              </div>
              <PickerOptionList
                id={`${menuId}-models`}
                className="acpmux-mp-models min-h-0 flex-1 overflow-y-auto px-2 pb-2"
                aria-label={searching ? searchText : starredView ? starredText : (selected?.name ?? modelText)}
              >
                {!searching && !starredView && (
                  <div className="px-3 pt-1 pb-2 text-detail font-medium text-muted">{selected?.name}</div>
                )}
                {selectedOther && !searching && blockedProfile(selected) ? (
                  <div className={emptyNote}>
                    {selected.folder?.state === "needs-trust"
                      ? t("picker.trustFirst")
                      : (selected.folder?.diagnostic ?? unavailableText)}
                  </div>
                ) : selectedOther && !searching && selected.folder?.state === "needs-enable" ? (
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
                  <div className={emptyNote}>{starredView && !query ? t("picker.starredEmpty") : noMatchesText}</div>
                ) : (
                  visible.map((model, index) => (
                    <div key={favoriteKey(owners.get(model)!.id, model.id)}>
                      {(searching || starredView) &&
                        (index === 0 || owners.get(visible[index - 1]!) !== owners.get(model)) && (
                          <div className="flex items-center gap-2 px-3 pt-3 pb-1.5 text-detail font-medium text-muted">
                            <AgentMark agent={owners.get(model)?.mark ?? owners.get(model)?.id} size={14} />
                            {owners.get(model)?.name}
                          </div>
                        )}
                      <div className="group relative flex items-center">
                        <PickerOption
                          type="button"
                          id={modelRowId(model)}
                          data-key={`model:${model.id}`}
                          selected={index === active}
                          aria-checked={model.id === props.model && owners.get(model)?.ids.includes(harness ?? "")}
                          className={`acpmux-mp-row ${modelRow} ${rowFill(index === active)} ${model.id === props.model ? "pr-16" : "pr-9"}${index === active ? " acpmux-mp-active" : ""}`}
                          onPointerEnter={() => setActive(index)}
                          disabled={Boolean(model.unavailable)}
                          onClick={() => selectModel(model)}
                          active={index === active}
                        >
                          <span className="acpmux-menu-label min-w-0 flex-1">
                            {isDefaultChoice(model) ? t("picker.default") : model.name}
                          </span>
                          {searching && (parsed.effort || parsed.fast) && (
                            <span className="acpmux-mp-combo flex-none text-detail text-dim">
                              {[modelEffort(model, parsed.effort), parsed.fast ? fastText : undefined]
                                .filter(Boolean)
                                .join(" · ")}
                            </span>
                          )}
                          {model.unavailable && (
                            <span className="flex-none text-detail text-dim">{unavailableText}</span>
                          )}
                        </PickerOption>
                        <span className="pointer-events-none absolute right-1.5 flex items-center">
                          <button
                            type="button"
                            className={`acpmux-mp-favorite pointer-events-auto grid size-6 cursor-pointer place-items-center rounded-md border-0 bg-transparent p-0 text-muted hover:text-fg ${favorites.has(favoriteKey(owners.get(model)!.id, model.id)) ? "" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 focus-visible:opacity-100"}`}
                            aria-label={`${starredText}: ${model.name}`}
                            aria-pressed={favorites.has(favoriteKey(owners.get(model)!.id, model.id))}
                            title={starredText}
                            onClick={() => toggleFavorite(model)}
                          >
                            <StarGlyph filled={favorites.has(favoriteKey(owners.get(model)!.id, model.id))} size={13} />
                          </button>
                          {model.id === props.model && owners.get(model)?.ids.includes(harness ?? "") && (
                            <span className="grid size-6 place-items-center text-muted">
                              <CheckIcon />
                            </span>
                          )}
                        </span>
                      </div>
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
                    <span className="acpmux-menu-label min-w-0 flex-1 truncate">{t("picker.olderModels")}</span>
                    <span className="flex-none text-detail text-dim">{olderCount}</span>
                    <span className={`flex-none ${olderOpen ? "rotate-180" : ""}`} aria-hidden="true">
                      <ChevronIcon />
                    </span>
                  </button>
                )}
              </PickerOptionList>
              {catalogRefresh && <ModelPickerRefresh state={catalogRefresh} />}
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
          </PickerDialog>,
          portalContainer ?? document.body,
        )}
    </span>
  );
}
