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

type HarnessChoice = {
  id: string;
  ids: string[];
  name: string;
  models: { id: string; name?: string; unavailable?: string }[];
  unavailable?: string;
  acpmuxHarness?: string;
  pickable: boolean;
  /** A profile from the chat's folder (`<folder>/.cmux/harnesses/<id>.toml`) and its state. */
  folder?: ModelPickerProps["catalog"][number]["folder"];
  /** The brand the row's mark draws (a folder profile's `icon` or `family`, else its id). */
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

function uniqueHarnesses(catalog: ModelPickerProps["catalog"]): HarnessChoice[] {
  // The chat folder's own profiles stand apart, after the harnesses, and never merge by name.
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

/// The composer model picker: one harness-and-model button opens a stable two-column picker.
/// The real search field receives focus immediately, and the selected harness's fixed model order
/// keeps keyboard muscle memory intact between openings.
export function ModelPicker(props: ModelPickerProps) {
  const { catalog, harness, label, onLand, onHarness, onHarnessHint, onHarnessEnable, fastMode, catalogRefresh } =
    props;
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
  const [favoritesOnly, setFavoritesOnly] = useState(false);
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
  const models = useMemo(() => choicesFor(selected), [selected]);
  const visible = useMemo(() => {
    const matching = query ? models.filter((model) => matches(model, query)) : models;
    return favoritesOnly ? matching.filter((model) => favorites.has(model.id)) : matching;
  }, [favorites, favoritesOnly, models, query]);
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
    setActive(
      Math.max(
        0,
        models.findIndex((model) => model.id === props.model),
      ),
    );
    setOpen(true);
    if (open) search.current?.focus();
    else trigger.current?.focus();
  }, [current?.id, harness, harnesses, models, open, props.model]);
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
  useEffect(() => {
    if (active >= visible.length) setActive(Math.max(visible.length - 1, 0));
  }, [active, visible.length]);

  const selectModel = (model: ModelChoice) => {
    if (model.unavailable || !selected?.pickable) return;
    if (!selected?.ids.includes(harness ?? "")) {
      if (selected?.acpmuxHarness) onHarness?.(selected.acpmuxHarness);
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
  const move = (step: number) =>
    setActive((index) => (visible.length ? (index + step + visible.length) % visible.length : 0));
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
      menu.current?.querySelectorAll<HTMLElement>(".acpmux-mp-harness")[activeHarness]?.focus();
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
  const modelLabel = selected?.ids.includes(harness ?? "") ? label : (selected?.name ?? label);
  // A folder profile waiting for Enable asks for it from the click or key press itself: the host's
  // confirmation takes that gesture (no await before the request).
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
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        data-menu={modelText}
        aria-label={modelText}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onKeyDown={(event) => {
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
        <AgentMark agent={current?.id ?? harness} size={15} />
        <span className="acpmux-model-name">{modelLabel}</span>
        <ChevronIcon />
      </button>
      {open && (
        <div
          ref={menu}
          id={menuId}
          className="acpmux-menu acpmux-menu-end acpmux-mp acpmux-mp-t3"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the popover is positioned by the shared anchor helper.
          role="dialog"
          aria-label={modelText}
          style={menuStyle}
        >
          <div className="acpmux-mp-search acpmux-menu-search">
            <SearchIcon size={15} />
            <span className="acpmux-menu-search-value" aria-hidden="true">
              {query || searchText}
            </span>
            <input
              ref={search}
              type="search"
              // oxlint-disable-next-line jsx-a11y/no-redundant-roles -- the combobox role exposes the inline model list.
              role="combobox"
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
              onKeyDown={keyDown}
            />
          </div>
          <div className="acpmux-mp-columns">
            {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rich harness rows need icons and prewarm states. */}
            <div className="acpmux-mp-harnesses">
              <button
                type="button"
                className="acpmux-mp-harness-favorites"
                aria-label={modelText}
                aria-pressed={favoritesOnly}
                title={modelText}
                onClick={() => setFavoritesOnly((value) => !value)}
              >
                <span aria-hidden="true">★</span>
              </button>
              {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rich harness rows need icons and prewarm states. */}
              <div className="acpmux-mp-harness-list" role="listbox" aria-label={harnessText}>
                <div className="acpmux-mp-harness-list-inner">
                  {harnesses.map((entry, index) => [
                    index === firstProfile && (
                      <div key="folder-section" className="acpmux-mp-section" role="presentation">
                        {t("picker.thisFolder")}
                      </div>
                    ),
                    <button
                      type="button"
                      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a rich button row is the selectable option.
                      role="option"
                      key={entry.folder ? `folder:${entry.id}` : entry.name}
                      aria-selected={entry.ids.includes(selectedHarness ?? "")}
                      aria-disabled={blockedProfile(entry) || undefined}
                      disabled={!entry.pickable}
                      className="acpmux-mp-harness"
                      tabIndex={index === activeHarness ? 0 : -1}
                      onKeyDown={(event) => {
                        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                          event.preventDefault();
                          const step = event.key === "ArrowDown" ? 1 : -1;
                          const next = (index + step + harnesses.length) % harnesses.length;
                          setActiveHarness(next);
                          setSelectedHarness(harnesses[next]?.id);
                          setQuery("");
                          event.currentTarget.parentElement
                            ?.querySelectorAll<HTMLElement>(".acpmux-mp-harness")
                            [next]?.focus();
                        } else if (event.key === "Enter" && enableProfile(entry)) {
                          event.preventDefault();
                        } else if (event.key === "ArrowRight" || event.key === "Enter") {
                          event.preventDefault();
                          search.current?.focus();
                        }
                      }}
                      onPointerEnter={() => onHarnessHint?.(entry.acpmuxHarness ?? entry.id)}
                      onClick={() => {
                        if (enableProfile(entry)) return;
                        setSelectedHarness(entry.id);
                        setActiveHarness(index);
                        setQuery("");
                        setActive(0);
                      }}
                    >
                      <AgentMark agent={entry.mark ?? entry.id} size={16} />
                      <span>{entry.name}</span>
                      {folderNote(entry) && <span className="acpmux-menu-description">{folderNote(entry)}</span>}
                      {entry.ids.includes(harness ?? "") && <CheckIcon />}
                    </button>,
                  ])}
                </div>
              </div>
            </div>
            <div
              id={`${menuId}-models`}
              className="acpmux-mp-models"
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- model rows carry marks, status and keyboard state.
              role="listbox"
              aria-label={selected?.name ?? modelText}
            >
              {selectedOther && blockedProfile(selected) ? (
                // A folder profile that cannot start says why, in place of its models.
                <div className="acpmux-mp-empty">
                  {selected.folder?.state === "needs-trust"
                    ? t("picker.trustFirst")
                    : (selected.folder?.diagnostic ?? unavailableText)}
                </div>
              ) : selectedOther && selected.folder?.state === "needs-enable" ? (
                <button type="button" className="acpmux-mp-row" onClick={() => enableProfile(selected)}>
                  <span className="acpmux-menu-label">{t("harness.enable")}</span>
                </button>
              ) : selectedOther && selected.folder && visible.length === 0 && !query ? (
                // An enabled folder profile that lists no models starts a new chat on its own.
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
                visible.map((model, index) => (
                  <div className="acpmux-mp-row-shell" key={model.id}>
                    <button
                      type="button"
                      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a rich button row is the selectable option.
                      role="option"
                      id={modelRowId(model.id)}
                      data-key={`model:${model.id}`}
                      aria-selected={index === active}
                      aria-checked={model.id === props.model}
                      className={`acpmux-mp-row${index === active ? " acpmux-mp-active" : ""}`}
                      onPointerEnter={() => setActive(index)}
                      disabled={Boolean(model.unavailable)}
                      onClick={() => selectModel(model)}
                    >
                      <span className="acpmux-mp-row-main">
                        <span className="acpmux-menu-label">{model.name}</span>
                        <span className="acpmux-mp-row-subtitle">
                          <AgentMark agent={selected?.id} size={12} />
                          {selected?.name}
                        </span>
                      </span>
                      {index < 4 && <span className="acpmux-mp-hotkey">⌘{index + 1}</span>}
                      {model.unavailable && <span className="acpmux-menu-description">{unavailableText}</span>}
                      {model.id === props.model && <CheckIcon />}
                    </button>
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
                ))
              )}
            </div>
          </div>
          {(fastMode || catalogRefresh) && (
            <div className="acpmux-mp-footer">
              {fastMode && (
                <button
                  type="button"
                  className="acpmux-mp-fast"
                  aria-pressed={fastMode.currentValue === fastMode.onValue}
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
          )}
        </div>
      )}
    </span>
  );
}
