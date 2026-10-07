import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { AgentMark } from "../shared/AgentMark";
import { agentName } from "./agents";
import { isDefaultChoice } from "./defaultChoice";
import { CheckIcon, ChevronIcon, PICKER_LABELS, SearchIcon } from "./ComposerPickers";
import { useT } from "./i18n";
import type { ModelPickerProps } from "./modelPickerLayout";
import { registerPicker } from "./pickerOpeners";
import { useUiAnchor } from "../../ui/anchor";
import { usePopoverTrigger } from "./popoverTrigger";

type HarnessChoice = {
  id: string;
  name: string;
  models: { id: string; name?: string; unavailable?: string }[];
  unavailable?: string;
};

type ModelChoice = { id: string; name: string; unavailable?: string; version: number[]; order: number };

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
  const result: HarnessChoice[] = [];
  const byName = new Map<string, HarnessChoice>();
  for (const entry of catalog) {
    const name = agentName(entry.id, entry.name);
    const existing = byName.get(name);
    if (!existing) {
      const next = { id: entry.id, name, models: [...entry.models], unavailable: entry.unavailable };
      result.push(next);
      byName.set(name, next);
      continue;
    }
    const known = new Set(existing.models.map((model) => model.id));
    for (const model of entry.models) if (!known.has(model.id)) existing.models.push(model);
    existing.unavailable ??= entry.unavailable;
  }
  return result;
}

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
  const { catalog, harness, label, onLand, onHarness, onHarnessHint } = props;
  const t = useT();
  const modelText = t(PICKER_LABELS.model) === PICKER_LABELS.model ? "Model" : t(PICKER_LABELS.model);
  const searchText = t("picker.search") === "picker.search" ? "Search models" : t("picker.search");
  const harnessText = t("picker.harness") === "picker.harness" ? "Harness" : t("picker.harness");
  const noMatchesText = t("picker.noMatches") === "picker.noMatches" ? "No matching models" : t("picker.noMatches");
  const unavailableText = t("picker.unavailable") === "picker.unavailable" ? "Unavailable" : t("picker.unavailable");
  const [open, setOpen] = useState(false);
  const [selectedHarness, setSelectedHarness] = useState(harness);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const menuId = useId();
  const harnesses = useMemo(() => uniqueHarnesses(catalog), [catalog]);
  const current = harnesses.find((entry) => entry.id === harness) ?? harnesses[0];
  const selected = harnesses.find((entry) => entry.id === selectedHarness) ?? current;
  const models = useMemo(() => choicesFor(selected), [selected]);
  const visible = useMemo(() => (query ? models.filter((model) => matches(model, query)) : models), [models, query]);
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  const close = useCallback(() => {
    setOpen(false);
    onHarnessHint?.(undefined);
  }, [onHarnessHint]);
  const show = useCallback(() => {
    setSelectedHarness(harness ?? current?.id);
    setQuery("");
    setActive(Math.max(0, models.findIndex((model) => model.id === props.model)));
    setOpen(true);
    if (open) search.current?.focus();
    else trigger.current?.focus();
  }, [current?.id, harness, models, open, props.model]);
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
      if (!root.current?.contains(event.target as Node)) close();
    };
    const blur = () => close();
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
    if (active >= visible.length) setActive(Math.max(visible.length - 1, 0));
  }, [active, visible.length]);

  const selectModel = (model: ModelChoice) => {
    if (selected?.id !== harness) {
      onHarness?.(selected?.id ?? "");
      close();
      return;
    }
    onLand(model.id);
    close();
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
    } else if (event.key === "Enter") {
      event.preventDefault();
      const model = visible[active];
      if (model) selectModel(model);
    } else if (/^[1-9]$/.test(event.key) && !event.metaKey && !event.altKey) {
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
  const modelLabel = selected?.id === harness ? label : selected?.name ?? label;
  return (
    <span ref={root} className="acpmux-picker acpmux-model" style={{ position: "relative" }}>
      <button
        ref={trigger}
        type="button"
        role="combobox"
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
              role="combobox"
              aria-label={searchText}
              aria-autocomplete="list"
              aria-controls={`${menuId}-models`}
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
            <div className="acpmux-mp-harnesses" role="listbox" aria-label={harnessText}>
              {harnesses.map((entry) => (
                <button
                  type="button"
                  role="option"
                  key={entry.name}
                  aria-selected={entry.id === selected?.id}
                  className="acpmux-mp-harness"
                  onPointerEnter={() => onHarnessHint?.(entry.id)}
                  onClick={() => {
                    setSelectedHarness(entry.id);
                    setQuery("");
                    setActive(0);
                  }}
                >
                  <AgentMark agent={entry.id} size={16} />
                  <span>{entry.name}</span>
                  {entry.id === harness && <CheckIcon />}
                </button>
              ))}
            </div>
            <div
              id={`${menuId}-models`}
              className="acpmux-mp-models"
              role="listbox"
              aria-label={selected?.name ?? modelText}
            >
              {visible.length === 0 ? (
                <div className="acpmux-mp-empty">{noMatchesText}</div>
              ) : (
                visible.map((model, index) => (
                  <button
                    type="button"
                    role="option"
                    key={model.id}
                    data-key={`model:${model.id}`}
                    aria-selected={index === active}
                    aria-checked={model.id === props.model}
                    className={`acpmux-mp-row${index === active ? " acpmux-mp-active" : ""}`}
                    onPointerEnter={() => setActive(index)}
                    onClick={() => selectModel(model)}
                  >
                    <span className="acpmux-menu-label">{model.name}</span>
                    {model.unavailable && <span className="acpmux-menu-description">{unavailableText}</span>}
                    {model.id === props.model && <CheckIcon />}
                  </button>
                ))
              )}
            </div>
          </div>
        </div>
      )}
    </span>
  );
}
