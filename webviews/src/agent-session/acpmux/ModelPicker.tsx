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
import { Autocomplete, useFilter } from "react-aria-components/Autocomplete";
import { Input } from "react-aria-components/Input";
import { ListBox, ListBoxItem } from "react-aria-components/ListBox";
import { SearchField } from "react-aria-components/SearchField";
import { AgentMark } from "../shared/AgentMark";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { Icon } from "./icons/Icon";
import { currentLanguage, useT } from "./i18n";
import {
  blockedProfile,
  choicesFor,
  uniqueHarnesses,
  type HarnessChoice,
  type ModelChoice,
} from "./modelPickerChoices";
import type { ModelPickerProps } from "./modelPickerLayout";
import { registerPicker } from "./pickerOpeners";
import { useUiAnchor } from "../../ui/anchor";
import { usePopoverTrigger } from "./popoverTrigger";
import { PickerButton, PickerDialog, PickerOption, PickerOptionList } from "../../ui/PickerPrimitives";

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
  const search = useRef<HTMLDivElement>(null);
  const menuId = useId();
  const harnesses = useMemo(() => uniqueHarnesses(catalog), [catalog]);
  const { contains } = useFilter({ sensitivity: "base" });
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
  // The model surface opens beside the chip so the result list stays next to the control that
  // owns it. The anchor flips to inline-start only when the viewport cannot fit the surface.
  const menuStyle = useUiAnchor(trigger, menu, open, { side: props.placement ?? "inline-end", align: "start" });
  const focusSearch = useCallback(() => {
    search.current?.querySelector<HTMLInputElement>("input")?.focus();
  }, []);
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
    if (open) focusSearch();
    else trigger.current?.focus();
  }, [current?.id, focusSearch, harness, harnesses, models, open, props.model]);
  const showRef = useRef(show);
  showRef.current = show;
  const toggle = open ? (_next: boolean) => close() : setOpen;
  const press = usePopoverTrigger(open, toggle, show);

  useLayoutEffect(() => {
    if (open) focusSearch();
  }, [focusSearch, open]);
  useEffect(() => {
    if (open) focusSearch();
  }, [focusSearch, open]);
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
      event.stopPropagation();
      move(["n", "j"].includes(event.key.toLowerCase()) ? 1 : -1);
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      event.stopPropagation();
      move(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      event.stopPropagation();
      move(-1);
    } else if (event.key === "ArrowLeft" && !query) {
      event.preventDefault();
      event.stopPropagation();
      menu.current?.querySelectorAll<HTMLElement>(".acpmux-mp-harness")[activeHarness]?.focus();
    } else if (event.key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
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
        event.stopPropagation();
        selectModel(model);
      }
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
      trigger.current?.focus();
    }
  };
  const modelLabel = selected?.ids.includes(harness ?? "") ? label : (selected?.name ?? label);
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
  const showHarnesses = query.trim().length === 0;
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
            focusSearch();
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
          <Autocomplete
            inputValue={query}
            onInputChange={(value) => {
              setQuery(value);
              setActive(0);
            }}
            filter={contains}
          >
            <SearchField
              ref={search}
              className="acpmux-mp-search acpmux-menu-search"
              aria-label={searchText}
              aria-activedescendant={visible[active] ? modelRowId(visible[active].id) : undefined}
              onKeyDown={keyDown}
            >
              <SearchIcon size={15} />
              <Input
                type="search"
                role="combobox"
                aria-label={searchText}
                aria-controls={`${menuId}-models`}
                placeholder={searchText}
              />
            </SearchField>
            <div className={`acpmux-mp-columns${showHarnesses ? "" : " acpmux-mp-searching"}`}>
              {showHarnesses && (
                <>
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
                    <PickerOptionList className="acpmux-mp-harness-list" aria-label={harnessText}>
                      <div className="acpmux-mp-harness-list-inner">
                        {harnesses.map((entry, index) => [
                          index === firstProfile && (
                            <div key="folder-section" className="acpmux-mp-section" role="presentation">
                              {t("picker.thisFolder")}
                            </div>
                          ),
                          <PickerOption
                            type="button"
                            key={entry.folder ? `folder:${entry.id}` : entry.name}
                            aria-selected={entry.ids.includes(selectedHarness ?? "")}
                            aria-disabled={blockedProfile(entry) || undefined}
                            disabled={!entry.pickable}
                            title={entry.name}
                            className="acpmux-mp-harness"
                            selected={entry.ids.includes(selectedHarness ?? "")}
                            keyboard={(event) => {
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
                                focusSearch();
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
                            active={index === activeHarness}
                          >
                            <AgentMark agent={entry.mark ?? entry.id} size={16} />
                            <span>{entry.name}</span>
                            {folderNote(entry) && <span className="acpmux-menu-description">{folderNote(entry)}</span>}
                            {entry.ids.includes(harness ?? "") && (
                              <span className="acpmux-mp-harness-check">
                                <CheckIcon />
                              </span>
                            )}
                          </PickerOption>,
                        ])}
                      </div>
                    </PickerOptionList>
                  </div>
                </>
              )}
              {selectedOther && blockedProfile(selected) ? (
                <div
                  className="acpmux-mp-models"
                  id={`${menuId}-models`}
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- empty and setup states share the same listbox contract as model rows.
                  role="listbox"
                  aria-label={selected?.name ?? modelText}
                >
                  <div className="acpmux-mp-empty">
                    {selected.folder?.state === "needs-trust"
                      ? t("picker.trustFirst")
                      : (selected.folder?.diagnostic ?? unavailableText)}
                  </div>
                </div>
              ) : selectedOther && selected.folder?.state === "needs-enable" ? (
                <div
                  className="acpmux-mp-models"
                  id={`${menuId}-models`}
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- empty and setup states share the same listbox contract as model rows.
                  role="listbox"
                  aria-label={selected?.name ?? modelText}
                >
                  <button type="button" className="acpmux-mp-row" onClick={() => enableProfile(selected)}>
                    <span className="acpmux-menu-label">{t("harness.enable")}</span>
                  </button>
                </div>
              ) : selectedOther && selected.folder && visible.length === 0 && !query ? (
                <div
                  className="acpmux-mp-models"
                  id={`${menuId}-models`}
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- empty and setup states share the same listbox contract as model rows.
                  role="listbox"
                  aria-label={selected?.name ?? modelText}
                >
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
                </div>
              ) : visible.length === 0 ? (
                <div
                  className="acpmux-mp-models"
                  id={`${menuId}-models`}
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- empty and setup states share the same listbox contract as model rows.
                  role="listbox"
                  aria-label={selected?.name ?? modelText}
                >
                  <div className="acpmux-mp-empty">{noMatchesText}</div>
                </div>
              ) : (
                <ListBox
                  id={`${menuId}-models`}
                  className="acpmux-mp-models"
                  aria-label={selected?.name ?? modelText}
                  selectionMode="single"
                  selectedKeys={visible[active] ? new Set([visible[active].id]) : new Set()}
                  onSelectionChange={(keys) => {
                    if (keys === "all") return;
                    const id = [...keys][0];
                    const index = visible.findIndex((model) => model.id === id);
                    if (index >= 0) setActive(index);
                  }}
                >
                  {visible.map((model, index) => (
                    <ListBoxItem
                      key={model.id}
                      id={model.id}
                      textValue={`${model.name} ${model.id}`}
                      data-key={`model:${model.id}`}
                      aria-checked={model.id === props.model}
                      ref={(node) => {
                        node?.setAttribute("aria-checked", String(model.id === props.model));
                      }}
                      className={`acpmux-mp-row${index === active ? " acpmux-mp-active" : ""}`}
                      onHoverStart={() => setActive(index)}
                      isDisabled={Boolean(model.unavailable)}
                      onPress={() => selectModel(model)}
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
                      <button
                        type="button"
                        className="acpmux-mp-favorite"
                        aria-label={`${modelText}: ${model.name}`}
                        aria-pressed={favorites.has(model.id)}
                        title={modelText}
                        onClick={(event) => {
                          event.stopPropagation();
                          toggleFavorite(model.id);
                        }}
                      >
                        <span aria-hidden="true">{favorites.has(model.id) ? "★" : "☆"}</span>
                      </button>
                    </ListBoxItem>
                  ))}
                </ListBox>
              )}
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
          </Autocomplete>
        </PickerDialog>
      )}
    </span>
  );
}
