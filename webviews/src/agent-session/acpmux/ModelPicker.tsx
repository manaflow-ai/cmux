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
import { AgentMark } from "../shared/AgentMark";
import { agentName } from "./agents";
import { isDefaultChoice } from "./defaultChoice";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { Icon } from "./icons/Icon";
import { currentLanguage, useT } from "./i18n";
import type { ModelPickerProps } from "./modelPickerLayout";
import { registerPicker } from "./pickerOpeners";
import { useUiAnchor } from "../../ui/anchor";
import { usePopoverTrigger } from "./popoverTrigger";
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
  models: { id: string; name?: string; unavailable?: string }[];
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
  unavailable?: string;
  version: number[];
  order: number;
};

function versionOf(model: { id: string; name?: string }): number[] {
  const text = model.name ?? model.id;
  const match = /\d+(?:\.\d+)*/.exec(text);
  return match ? match[0].split(".").map(Number) : (model.id.match(/\d+/g) ?? []).map(Number);
}

function compareVersions(a: ModelChoice, b: ModelChoice): number {
  const length = Math.max(a.version.length, b.version.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (a.version[index] ?? -1) - (b.version[index] ?? -1);
    if (difference !== 0) return difference;
  }
  return a.order - b.order;
}

function choicesFor(entry: HarnessChoice | undefined): ModelChoice[] {
  if (!entry) return [];
  const seen = new Set<string>();
  const choices = entry.models.flatMap((model, order) => {
    if (seen.has(model.id)) return [];
    seen.add(model.id);
    return [
      {
        id: model.id,
        name: isDefaultChoice(model) ? "Default" : model.name || model.id,
        unavailable: model.unavailable,
        version: versionOf(model),
        order,
      },
    ];
  });
  const defaults = choices.filter((choice) => isDefaultChoice(choice));
  const models = choices.filter((choice) => !isDefaultChoice(choice)).sort(compareVersions);
  // The list is deliberately stable. Newest and best models sit nearest the anchor at the bottom.
  return [...defaults, ...models];
}

/// A harness with more models than this shows a short list under "More models".
const SHORT_LIST = 5;

/// The models a long catalog keeps in view: defaults, the running model, the flagship (the
/// harness lists it first), the newest by version and every starred model.
function shortList(models: ModelChoice[], running: string | undefined, favorites: Set<string>): Set<string> {
  if (models.length <= SHORT_LIST) return new Set(models.map((model) => model.id));
  const named = models.filter((model) => !isDefaultChoice(model));
  const flagship = named.reduce<ModelChoice | undefined>(
    (first, model) => (!first || model.order < first.order ? model : first),
    undefined,
  );
  return new Set(
    models
      .filter(
        (model) =>
          isDefaultChoice(model) ||
          model.id === running ||
          model === flagship ||
          model === named.at(-1) ||
          favorites.has(model.id),
      )
      .map((model) => model.id),
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

/// A folder profile row the user cannot start yet: waiting for the folder's Trust answer, or broken.
const blockedProfile = (entry: HarnessChoice | undefined) =>
  entry?.folder?.state === "needs-trust" || entry?.folder?.state === "error";

function matches(model: ModelChoice, query: string): boolean {
  const text = `${model.name} ${model.id}`.toLowerCase();
  return query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .every((word) => text.includes(word));
}

/// A model row: the model, and the harness it belongs to (search lists every harness's matches).
type ModelRow = ModelChoice & { harness: HarnessChoice };

/// The composer model picker. It opens upward from the chip, so what matters most sits at the
/// bottom, nearest it: the running harness is the bottom harness row, and each harness's models
/// are one flat list, oldest at the top, newest below them, starred ones at the very bottom. The
/// running model is highlighted and checked; there are no section headers. Resting on or pressing
/// a harness branches its models out beside it; typing searches every harness. The search field
/// sits at the bottom and has focus as soon as the menu opens.
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
    fastMode,
    catalogRefresh,
  } = props;
  const t = useT();
  const modelText = t(PICKER_LABELS.model);
  const searchText = t("picker.search");
  const harnessText = t("picker.harness");
  const noMatchesText = t("picker.noMatches");
  const unavailableText = t("picker.unavailable");
  const modelRowId = (id: string) => `${menuId}-model-${encodeURIComponent(id)}`;
  const [open, setOpen] = useState(false);
  const [selectedHarness, setSelectedHarness] = useState(harness);
  const [activeHarness, setActiveHarness] = useState(0);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
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
  const menuId = useId();
  const harnesses = useMemo(() => uniqueHarnesses(catalog), [catalog]);
  const current = harnesses.find((entry) => entry.ids.includes(harness ?? "")) ?? harnesses[0];
  const selected = harnesses.find((entry) => entry.ids.includes(selectedHarness ?? "")) ?? current;
  // The running harness is the bottom row, nearest the chip; the folder's profiles sit furthest
  // up, each row naming its own state; the rest keep the catalog's order.
  const ordered = useMemo(() => {
    const others = harnesses.filter((entry) => entry !== current);
    return [
      ...others.filter((entry) => entry.folder),
      ...others.filter((entry) => !entry.folder),
      ...(current ? [current] : []),
    ];
  }, [current, harnesses]);
  // A long catalog shows a short list; "More models" at the top shows the rest in place.
  const [expanded, setExpanded] = useState(false);
  // One flat list: starred models sink to the bottom; a search lists every harness's matches.
  const { visible, hidden } = useMemo(() => {
    const rows = (entry: HarnessChoice | undefined): ModelRow[] =>
      entry ? choicesFor(entry).map((model) => ({ ...model, harness: entry })) : [];
    let matching = query ? ordered.flatMap(rows).filter((model) => matches(model, query)) : rows(selected);
    let hidden = 0;
    if (!query && !expanded) {
      const keep = shortList(matching, selected?.ids.includes(harness ?? "") ? props.model : undefined, favorites);
      hidden = matching.length - keep.size;
      matching = matching.filter((model) => keep.has(model.id));
    }
    return {
      hidden,
      visible: [
        ...matching.filter((model) => !favorites.has(model.id)),
        ...matching.filter((model) => favorites.has(model.id)),
      ],
    };
  }, [expanded, favorites, harness, ordered, props.model, query, selected]);
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
    setOpen(true);
    if (open) search.current?.focus();
    else trigger.current?.focus();
  }, [current?.id, harness, harnesses, open]);
  const showRef = useRef(show);
  showRef.current = show;
  const toggle = open ? (_next: boolean) => close() : setOpen;
  const press = usePopoverTrigger(open, toggle, show);

  useLayoutEffect(() => {
    if (open) search.current?.focus();
  }, [open]);
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
      if (event.metaKey && event.ctrlKey && event.shiftKey && event.key.toLowerCase() === "m") {
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
  // A new list starts on the running model, else on its bottom row (nearest the chip), scrolled
  // to the bottom.
  const listKey = `${open}:${selected?.id}:${query}`;
  useLayoutEffect(() => setExpanded(false), [open, selected?.id]);
  const models = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!open) return;
    const running = query ? -1 : visible.findIndex((model) => model.id === props.model);
    setActive(running >= 0 ? running : Math.max(visible.length - 1, 0));
    if (models.current) models.current.scrollTop = models.current.scrollHeight;
    // Only a new list moves the highlight; a star or a catalog refresh keeps it where it is.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, [listKey]);
  useEffect(() => {
    if (active >= visible.length) setActive(Math.max(visible.length - 1, 0));
  }, [active, visible.length]);
  // The models branch out beside their harness row: their bottom lines up with its bottom.
  const harnessList = useRef<HTMLDivElement>(null);
  const [branchLift, setBranchLift] = useState(0);
  useLayoutEffect(() => {
    if (!open || query) {
      setBranchLift(0);
      return;
    }
    const list = harnessList.current;
    const row = list?.querySelector<HTMLElement>('.acpmux-mp-harness[aria-selected="true"]');
    if (!list || !row) return;
    setBranchLift(Math.max(0, list.getBoundingClientRect().bottom - row.getBoundingClientRect().bottom));
  }, [open, query, selected?.id, ordered.length]);

  const selectModel = (model: ModelRow) => {
    const owner = model.harness;
    if (model.unavailable || !owner.pickable) return;
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
  // Opening "More models" keeps the highlight on its model; Up from the top row lands just above it.
  const keep = useRef<{ id: string; step: number }>(undefined);
  const expand = (step = 0) => {
    const model = visible[active];
    if (model) keep.current = { id: model.id, step };
    setExpanded(true);
  };
  useLayoutEffect(() => {
    if (!keep.current) return;
    const { id, step } = keep.current;
    keep.current = undefined;
    const index = visible.findIndex((model) => model.id === id);
    if (index >= 0) setActive(Math.max(0, index + step));
  }, [visible]);
  const move = (step: number) => {
    if (step < 0 && active === 0 && hidden > 0) expand(step);
    else setActive((index) => (visible.length ? (index + step + visible.length) % visible.length : 0));
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
      menu.current
        ?.querySelectorAll<HTMLElement>(".acpmux-mp-harness")
        [Math.max(0, ordered.indexOf(harnesses[activeHarness]!))]?.focus();
    } else if (event.key === "Enter") {
      event.preventDefault();
      const model = visible[active];
      if (model) selectModel(model);
    } else if (
      /^[1-9]$/.test(event.key) &&
      !event.ctrlKey &&
      !event.altKey &&
      (!event.metaKey || Number(event.key) <= 4)
    ) {
      // 1 is the bottom row, nearest the chip.
      const model = visible[visible.length - Number(event.key)];
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
  const selectedOther = !query && selected !== undefined && !selected.ids.includes(harness ?? "");
  // Rest on or press a harness: its models branch out beside it.
  const branch = (entry: HarnessChoice) => {
    setSelectedHarness(entry.id);
    setActiveHarness(harnesses.indexOf(entry));
    setQuery("");
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
          className="acpmux-menu acpmux-menu-end acpmux-mp acpmux-mp-t3"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the popover is positioned by the shared anchor helper.
          aria-label={modelText}
          style={menuStyle}
        >
          <div className="acpmux-mp-main">
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rich harness rows need icons and prewarm states. */}
            <PickerOptionList className="acpmux-mp-harness-list" aria-label={harnessText}>
              <div ref={harnessList} className="acpmux-mp-harness-list-inner">
                {ordered.map((entry) => {
                  const index = ordered.indexOf(entry);
                  const note = folderNote(entry) ?? (entry.folder ? t("picker.thisFolder") : undefined);
                  return (
                    <PickerOption
                      type="button"
                      key={entry.folder ? `folder:${entry.id}` : entry.name}
                      aria-selected={!query && entry.ids.includes(selectedHarness ?? "")}
                      aria-disabled={blockedProfile(entry) || undefined}
                      disabled={!entry.pickable}
                      className="acpmux-mp-harness"
                      selected={!query && entry.ids.includes(selectedHarness ?? "")}
                      keyboard={(event) => {
                        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                          event.preventDefault();
                          const step = event.key === "ArrowDown" ? 1 : -1;
                          const next = ordered[(index + step + ordered.length) % ordered.length]!;
                          branch(next);
                          event.currentTarget.parentElement
                            ?.querySelectorAll<HTMLElement>(".acpmux-mp-harness")
                            [ordered.indexOf(next)]?.focus();
                        } else if (event.key === "Enter" && enableProfile(entry)) {
                          event.preventDefault();
                        } else if (event.key === "ArrowRight" || event.key === "Enter") {
                          event.preventDefault();
                          search.current?.focus();
                        }
                      }}
                      onPointerEnter={() => {
                        onHarnessHint?.(entry.acpmuxHarness ?? entry.id);
                        if (!query) branch(entry);
                      }}
                      onClick={() => {
                        if (enableProfile(entry)) return;
                        branch(entry);
                      }}
                      active={harnesses.indexOf(entry) === activeHarness}
                    >
                      <AgentMark agent={entry.mark ?? entry.id} size={16} />
                      <span className="acpmux-mp-harness-name">{entry.name}</span>
                      {note && <span className="acpmux-menu-description">{note}</span>}
                      {entry.ids.includes(harness ?? "") ? <CheckIcon /> : <ChevronIcon />}
                    </PickerOption>
                  );
                })}
              </div>
            </PickerOptionList>
            <div className="acpmux-mp-search acpmux-menu-search">
              <SearchIcon size={15} />
              <span className="acpmux-menu-search-value" aria-hidden="true">
                {query || searchText}
              </span>
              <PickerComboboxInput
                ref={search}
                type="search"
                aria-label={searchText}
                aria-autocomplete="list"
                aria-controls={`${menuId}-models`}
                aria-activedescendant={visible[active] ? modelRowId(visible[active].id) : undefined}
                aria-expanded="true"
                value={query}
                placeholder={searchText}
                onChange={(event) => setQuery(event.target.value)}
                keyboard={keyDown}
              />
              {fastMode && (
                <button
                  type="button"
                  className="acpmux-mp-fast"
                  aria-pressed={fastMode.currentValue === fastMode.onValue}
                  title={fastMode.name}
                  onClick={() =>
                    fastMode.onPick(fastMode.currentValue === fastMode.onValue ? fastMode.offValue : fastMode.onValue)
                  }
                >
                  <span>{fastMode.name}</span>
                  <span className="acpmux-menu-description">
                    {fastMode.currentValue === fastMode.onValue ? fastMode.onLabel : fastMode.offLabel}
                  </span>
                </button>
              )}
              {catalogRefresh && (
                <button
                  type="button"
                  className="acpmux-mp-refresh"
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
          </div>
          <PickerOptionList
            ref={models}
            id={`${menuId}-models`}
            className="acpmux-mp-models"
            aria-label={query ? modelText : (selected?.name ?? modelText)}
            style={{ marginBottom: branchLift }}
          >
            {selectedOther && blockedProfile(selected) ? (
              <div className="acpmux-mp-empty">
                {selected.folder?.state === "needs-trust"
                  ? t("picker.trustFirst")
                  : (selected.folder?.diagnostic ?? unavailableText)}
              </div>
            ) : selectedOther && selected.folder?.state === "needs-enable" ? (
              <button type="button" className="acpmux-mp-row" onClick={() => enableProfile(selected)}>
                <span className="acpmux-menu-label">{t("harness.enable")}</span>
              </button>
            ) : selectedOther && selected.folder && visible.length === 0 ? (
              <button
                type="button"
                className="acpmux-mp-row"
                onClick={() => {
                  onHarness?.(selected.id);
                  close();
                }}
              >
                <span className="acpmux-menu-label">{t("picker.newChat")}</span>
              </button>
            ) : visible.length === 0 ? (
              <div className="acpmux-mp-empty">{noMatchesText}</div>
            ) : (
              <>
                {hidden > 0 && (
                  <button
                    type="button"
                    className="acpmux-mp-more"
                    aria-expanded="false"
                    onClick={() => {
                      expand();
                      search.current?.focus();
                    }}
                  >
                    <ChevronIcon />
                    <span className="acpmux-menu-label">{t("picker.moreModels")}</span>
                    <span className="acpmux-menu-description">{hidden}</span>
                  </button>
                )}
                {visible.map((model, index) => {
                  const fromChip = visible.length - index;
                  const running = model.id === props.model && model.harness.ids.includes(harness ?? "");
                  return (
                    <div className="acpmux-mp-row-shell" key={`${model.harness.id}:${model.id}`}>
                      <PickerOption
                        type="button"
                        id={modelRowId(model.id)}
                        data-key={`model:${model.id}`}
                        selected={index === active}
                        aria-checked={running}
                        className={`acpmux-mp-row${index === active ? " acpmux-mp-active" : ""}${running ? " acpmux-mp-current" : ""}`}
                        onPointerEnter={() => setActive(index)}
                        disabled={Boolean(model.unavailable)}
                        onClick={() => selectModel(model)}
                        active={index === active}
                      >
                        {query && <AgentMark agent={model.harness.mark ?? model.harness.id} size={14} />}
                        <span className="acpmux-menu-label">{model.name}</span>
                        {fromChip <= 4 && <span className="acpmux-mp-hotkey">⌘{fromChip}</span>}
                        {model.unavailable && <span className="acpmux-menu-description">{unavailableText}</span>}
                        {running && <CheckIcon />}
                      </PickerOption>
                      <button
                        type="button"
                        className="acpmux-mp-favorite"
                        aria-label={`${modelText}: ${model.name}`}
                        aria-pressed={favorites.has(model.id)}
                        title={modelText}
                        onClick={() => toggleFavorite(model.id)}
                      >
                        <span aria-hidden="true">{favorites.has(model.id) ? "★" : "☆"}</span>
                      </button>
                    </div>
                  );
                })}
              </>
            )}
          </PickerOptionList>
        </PickerDialog>
      )}
    </span>
  );
}
