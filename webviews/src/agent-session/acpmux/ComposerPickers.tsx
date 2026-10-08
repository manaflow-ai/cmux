import React, { useEffect, useId, useRef, useState } from "react";
import { sessionModels } from "./modelCatalog";
import {
  isDefaultChoice,
  loadResolvedDefaults,
  modelIdName,
  rememberResolvedDefault,
  resolvedModel,
} from "./defaultChoice";
import type { AcpmuxSnapshot } from "./model";
import { EffortPicker } from "./EffortPicker";
import { type StringKey, useT } from "./i18n";
import { ModelPicker } from "./ModelPicker";
import type { CatalogRefreshState } from "./modelPickerLayout";
import type { PickerCatalog } from "./modelCatalogData";
import { Popover } from "../../ui/Popover";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { registerPicker } from "./pickerOpeners";
import { useUiAnchor } from "../../ui/anchor";
import { usePopoverTrigger } from "./popoverTrigger";

/// Picker copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const PICKER_LABELS = {
  model: "picker.model",
  mode: "picker.mode",
  effort: "picker.effort",
  plan: "picker.plan",
  build: "picker.build",
  planHint: "picker.planHint",
  /// `{percent}` is the share of the context window used.
  context: "picker.context",
} as const satisfies Record<string, StringKey>;

/// A model and effort the viewer used, kept per viewer so the menu can offer it as one click.
export type Combo = { harness: string; model: string; effort?: string; effortName?: string };
/// A combo counts as used once it has held this long: model and effort land in separate updates.
export const RECENT_SETTLE_MS = 1500;
const RECENTS_KEY = "cmux.acpmux.recentModels";

/// The viewer's recent combos, newest first. Storage can be missing or blocked; then there are none.
export function loadRecents(): Combo[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(RECENTS_KEY) ?? "[]");
    return Array.isArray(value)
      ? value.filter(
          (combo): combo is Combo =>
            typeof combo?.harness === "string" &&
            typeof combo.model === "string" &&
            (combo.effort === undefined || typeof combo.effort === "string") &&
            (combo.effortName === undefined || typeof combo.effortName === "string"),
        )
      : [];
  } catch {
    return [];
  }
}

/// Puts `combo` first, once, and keeps the list short. Saving is best effort.
/// It builds on what is stored now, so another pane's newer combos aren't written over.
export function rememberCombo(recents: Combo[], combo: Combo): Combo[] {
  const key = (other: Combo) => `${other.harness}\u0000${other.model}\u0000${other.effort ?? ""}`;
  const same = (other: Combo) => key(other) === key(combo);
  const known = new Set<string>();
  const merged = [...loadRecents(), ...recents].filter((other) => !known.has(key(other)) && known.add(key(other)));
  if (merged[0] && same(merged[0])) return merged;
  const next = [combo, ...merged.filter((other) => !same(other))].slice(0, 12);
  try {
    localStorage.setItem(RECENTS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the list for this page only.
  }
  return next;
}

export type Choice = { id: string; name: string; description?: string; icon?: React.ReactNode; hint?: string };

/// Runs `run` after `ms` unless the returned cancel runs first.
export type SettleTimer = (run: () => void, ms: number) => () => void;

const browserSettleTimer: SettleTimer = (run, ms) => {
  const timer = setTimeout(run, ms);
  return () => clearTimeout(timer);
};

type Props = {
  snapshot: AcpmuxSnapshot;
  onModel(modelId: string): void;
  onMode(modeId: string): void;
  onEffort(configId: string, value: string): void;
  /// How long a combo must hold before it counts as recent.
  settleMs?: number;
  /// Schedules the settle check and returns its cancel; tests run it by hand.
  settleTimer?: SettleTimer;
  /// Starts a new chat in another harness (the model picker offers it).
  onHarness?(harness: string): void;
  /// The pointer or keyboard rests on a harness row (undefined: it left them), for a prewarm hint.
  onHarnessHint?(harness: string | undefined): void;
  /// Enables the chat folder's profile `id` (see ModelPickerProps.onHarnessEnable).
  onHarnessEnable?(folder: string, id: string): void;
  /// The model picker's room for side submenus (tests pass a fixed one; see ModelPicker).
  measurePickerRoom?(menu: HTMLElement): number;
  /// The Plan/Build toggle lives in the composer's + menu in the default pane.
  showPlan?: boolean;
  /// Runs the agent's compact command from the context popover; offered only when set and the
  /// agent lists a `compact` command.
  onCompact?(): void;
  /** Host-backed catalog refresh; transport stays outside the picker UI. */
  catalogRefresh?: CatalogRefreshState;
  /** Joined host catalog supplied by the app root; direct tests keep using the daemon catalog. */
  pickerCatalog?: PickerCatalog;
};

/// The composer bar's controls: the
/// permission mode (in the warning color when it skips approvals) and a
/// Plan/Build toggle after the attach button, then at the right the context
/// ring and one model chip that names the effort beside the model (its menu
/// holds both). Each control shows only when the agent offers it.
export function ComposerPickers({
  snapshot,
  onModel,
  onMode,
  onEffort,
  onHarness,
  onHarnessHint,
  onHarnessEnable,
  settleMs = RECENT_SETTLE_MS,
  settleTimer = browserSettleTimer,
  measurePickerRoom,
  showPlan = true,
  onCompact,
  catalogRefresh,
  pickerCatalog,
}: Props) {
  const t = useT();
  const summary = snapshot.summary;
  const pickerEntries: AcpmuxSnapshot["catalog"] = pickerCatalog
    ? [
        ...pickerCatalog.harnesses.map((entry) => ({
          id: entry.acpmuxHarness ?? entry.id,
          name: entry.name,
          models: entry.models,
          ...(entry.unavailable ? { unavailable: entry.unavailable } : {}),
          pickable: entry.pickable && entry.acpmuxHarness !== null,
        })),
        // The chat folder's own profiles are acpmux's alone; the model catalog never lists them.
        ...snapshot.catalog.filter((entry) => entry.folder),
      ]
    : snapshot.catalog;
  // An agent's own default reads "Default", never its "(Claude Code's choice)" phrasing.
  const models: Choice[] = sessionModels(snapshot.catalog, summary).map((choice) =>
    isDefaultChoice(choice) ? { ...choice, name: t("picker.default") } : choice,
  );
  const allModes: Choice[] = (summary?.modes?.availableModes ?? []).map((mode) => ({
    id: mode.id,
    name: mode.name || mode.id,
    description: mode.description,
  }));
  const plan = allModes.find((choice) => isPlan(choice.id));
  const modes = allModes.filter((choice) => choice !== plan);
  const currentId = summary?.modes?.currentModeId;
  const planning = plan !== undefined && currentId === plan.id;
  // Leaving Plan returns to the permission mode this session had before it, never another session's.
  const lastMode = useRef<{ sessionId?: string; mode?: string }>({});
  if (lastMode.current.sessionId !== summary?.sessionId) lastMode.current = { sessionId: summary?.sessionId };
  if (currentId && !planning) lastMode.current.mode = currentId;
  const mode = modes.find((choice) => choice.id === (planning ? lastMode.current.mode : currentId));
  const effort = summary?.configOptions?.find(
    (option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort",
  );
  const efforts: Choice[] = (effort?.options ?? []).map((option) => {
    const choice = { id: option.value, name: option.name || option.value };
    return isDefaultChoice(choice) ? { ...choice, name: t("picker.default") } : choice;
  });
  const fastOption = snapshot.summary?.configOptions?.find(
    (option) => option.id === "fast-mode" || /fast[ _-]?mode/i.test(option.name ?? ""),
  );
  const fastOn =
    fastOption?.options.find((option) => /^(on|true|enabled)$/i.test(option.value)) ?? fastOption?.options[1];
  const fastOff =
    fastOption?.options.find((option) => /^(off|false|disabled)$/i.test(option.value)) ?? fastOption?.options[0];
  const fastMode =
    fastOption?.name && fastOn && fastOff && fastOn.value !== fastOff.value
      ? {
          name: fastOption.name,
          currentValue: fastOption.currentValue,
          onValue: fastOn.value,
          offValue: fastOff.value,
          onLabel: fastOn.name ?? fastOn.value,
          offLabel: fastOff.name ?? fastOff.value,
          onPick: (value: string) => onEffort(fastOption.id, value),
        }
      : undefined;
  const model = models.find((choice) => choice.id === summary?.model);
  const effortName = efforts.find((choice) => choice.id === effort?.currentValue)?.name;
  // Recents follow what the session actually runs, whichever control changed it,
  // once it settles: a switch passes through the new model with the old effort.
  const [recents, setRecents] = useState(loadRecents);
  const harness = summary?.harness;
  // The chip draws a pick at once; the combo sequencing and the recents follow what the agent
  // reports (`confirmedModel`, set while a pick is unconfirmed).
  const shown = summary?.model;
  const current = summary?.confirmedModel ?? shown;
  const currentEffort = effort?.currentValue;
  const offersEffort = effort !== undefined;
  // A harness still starting reports nothing yet: what it draws is not a combo the viewer used.
  const switching = snapshot.switching !== undefined;
  useEffect(() => {
    if (switching || !harness || !current || (offersEffort && !currentEffort)) return;
    return settleTimer(
      () =>
        setRecents((list) =>
          rememberCombo(list, { harness, model: current, effort: currentEffort, effortName: effortName }),
        ),
      settleMs,
    );
  }, [switching, harness, current, currentEffort, offersEffort, effortName, settleMs, settleTimer]);
  // A combo for another model sends the model first, then its effort once the
  // agent reports that model and offers the effort; anything else drops it.
  const pending = useRef<
    { sessionId?: string; from?: string; model: string; effort: string; reached?: boolean } | undefined
  >(undefined);
  const effortId = effort?.id;
  const effortValues = (effort?.options ?? []).map((option) => option.value).join("\u0000");
  useEffect(() => {
    const wanted = pending.current;
    if (!wanted) return;
    // Dropped on a session switch, or once the session moves off the picked model (or never reaches it).
    const away = current !== wanted.model && (current !== wanted.from || wanted.reached);
    if (wanted.sessionId !== summary?.sessionId || away) {
      pending.current = undefined;
      return;
    }
    if (current === wanted.model) wanted.reached = true;
    if (current !== wanted.model || !effortId || !effortValues.split("\u0000").includes(wanted.effort)) return;
    pending.current = undefined;
    if (wanted.effort !== currentEffort) onEffort(effortId, wanted.effort);
  }, [summary?.sessionId, current, currentEffort, effortId, effortValues, onEffort]);
  // One pick of a model and effort: the model first, then the effort once the agent reports
  // that model offering it (the effect above); the same model only changes the effort.
  const land = (pickedModel: string, pickedEffort?: string) => {
    // Any new pick replaces a combo still waiting on its effort.
    pending.current = undefined;
    if (pickedModel !== shown) {
      pending.current = pickedEffort
        ? { sessionId: summary?.sessionId, from: current, model: pickedModel, effort: pickedEffort }
        : undefined;
      onModel(pickedModel);
    } else if (
      effort &&
      pickedEffort &&
      pickedEffort !== currentEffort &&
      efforts.some((choice) => choice.id === pickedEffort)
    )
      onEffort(effort.id, pickedEffort);
  };
  // A default model draws as the model it resolves to: the running session's, else the one this
  // harness's default last resolved to, else "Default".
  const defaulted = shown !== undefined && isDefaultChoice(model ?? { id: shown });
  // A harness still starting draws its last session's options, which name no model this chat runs.
  const resolvedNow = switching ? undefined : resolvedModel(summary);
  useEffect(() => {
    if (harness && resolvedNow) rememberResolvedDefault(harness, resolvedNow);
  }, [harness, resolvedNow]);
  const resolvedId = defaulted ? (resolvedNow ?? (harness ? loadResolvedDefaults()[harness] : undefined)) : undefined;
  const resolvedName =
    resolvedId &&
    (models.find((choice) => choice.id === resolvedId && !isDefaultChoice(choice))?.name ?? modelIdName(resolvedId));
  const modelName = defaulted ? (resolvedName ?? t("picker.default")) : (model?.name ?? summary?.model);
  const usage = summary?.usage;
  const compact = onCompact && snapshot.commands?.some((command) => command.name === "compact") ? onCompact : undefined;

  return (
    <div className="acpmux-chips">
      {(models.length > 0 || snapshot.catalog.length > 0 || harness) && (
        <ModelPicker
          catalog={pickerEntries}
          harness={harness}
          model={shown}
          label={modelName ?? t(PICKER_LABELS.model)}
          efforts={efforts}
          effort={currentEffort}
          recents={recents}
          onLand={(pickedModel) => land(pickedModel)}
          onEffort={(value) => {
            pending.current = undefined;
            if (effort) onEffort(effort.id, value);
          }}
          onHarness={onHarness}
          onHarnessHint={onHarnessHint}
          onHarnessEnable={onHarnessEnable}
          fastMode={fastMode}
          catalogRefresh={catalogRefresh}
          harnessNotes={
            snapshot.switching?.phase === "failed"
              ? { [snapshot.switching.harness]: t("switch.failedShort") }
              : undefined
          }
          measureRoom={measurePickerRoom}
        />
      )}
      {/* The context ring stays immediately to the right of the model control. */}
      {(usage || summary?.sessionId) && (
        <ContextRing used={usage?.used} size={usage?.size} onCompact={compact} working={snapshot.isWorking} />
      )}
      {/* Reasoning is its own stable control, separate from the model and harness picker. */}
      {effort && efforts.length > 0 && (
        <EffortPicker
          label={t(PICKER_LABELS.effort)}
          efforts={efforts}
          current={effort.currentValue}
          model={modelName}
          chevron={<ChevronIcon />}
          onPick={(value) => {
            pending.current = undefined;
            onEffort(effort.id, value);
          }}
        />
      )}
      <span className="acpmux-chips-spacer" />
      {modes.length > 0 && (
        <AccessMenu label={t(PICKER_LABELS.mode)} modes={modes} current={mode?.id} onMode={onMode} />
      )}
      {showPlan && plan && (
        <button
          type="button"
          className="acpmux-plan"
          aria-pressed={planning}
          title={t(PICKER_LABELS.planHint)}
          onClick={() => onMode(planning ? (lastMode.current.mode ?? modes[0]?.id ?? plan.id) : plan.id)}
        >
          {planning ? <PlanIcon /> : <BuildIcon />}
          <span>{planning ? t(PICKER_LABELS.plan) : t(PICKER_LABELS.build)}</span>
        </button>
      )}
    </div>
  );
}

/** The permission control stays quiet in the footer: a lock names the control and the menu
 * carries the mode title and one-line explanation. Base UI owns focus, typeahead and Escape. */
function AccessMenu({
  label,
  modes,
  current,
  onMode,
}: {
  label: string;
  modes: Choice[];
  current?: string;
  onMode(modeId: string): void;
}) {
  const [open, setOpen] = useState(false);
  const value = current ?? modes[0]?.id ?? "";
  const currentMode = modes.find((choice) => choice.id === value);
  return (
    <span className={`acpmux-mode acpmux-access${current && unrestricted(current) ? " acpmux-unrestricted" : ""}`}>
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-picker-button acpmux-access-trigger" label={label} aria-haspopup="menu">
          <LockIcon />
          <span className="acpmux-mode-text">{currentMode?.name ?? label}</span>
          <ChevronIcon />
        </MenuButton>
        <MenuPopup side="top" align="start" className="acpmux-access-menu">
          <MenuRadioGroup
            value={value}
            onValueChange={(next) => {
              onMode(next);
              setOpen(false);
            }}
          >
            {modes.map((choice) => (
              <MenuRadioItem
                key={choice.id}
                value={choice.id}
                className={`acpmux-access-item${unrestricted(choice.id) ? " acpmux-unrestricted" : ""}`}
              >
                <span className="acpmux-access-item-icon" aria-hidden="true">
                  {choice.icon ?? <ShieldIcon />}
                </span>
                <span className="acpmux-menu-text">
                  <span className="acpmux-menu-label">{choice.name}</span>
                  {choice.description ? <span className="acpmux-menu-description">{choice.description}</span> : null}
                </span>
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// Plan modes (an id ending in "plan") read and propose without editing; the toggle sits apart from the permission chip.
export function isPlan(modeId: string): boolean {
  return /(^|[-_])plan$/i.test(modeId);
}

/// How much of the context window the session has used, as a ring that fills. A click opens
/// the details: the share used, tokens used of the window, and Compact when the agent offers it.
export function ContextRing({
  used,
  size,
  onCompact,
  working = false,
}: {
  used?: number;
  size?: number;
  onCompact?(): void;
  working?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  // Whether the details were open when a press on the ring began. That press is also the
  // popover's outside press, which can close it before the click lands; the click then
  // toggles from the state the press saw, so the press that closed it does not reopen it.
  const openAtPress = useRef<boolean | null>(null);
  const known = used !== undefined && size !== undefined && size > 0;
  const fraction = known ? Math.min(1, Math.max(0, used / size)) : 0;
  const percent = Math.round(fraction * 100);
  const label = known ? t(PICKER_LABELS.context, { percent }) : t("context.title");
  const radius = 6.5;
  const circumference = 2 * Math.PI * radius;
  useEffect(() => registerPicker(t("context.title"), () => setOpen(true)), [t]);
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const full = fraction >= 0.8 ? " acpmux-context-full" : "";
  return (
    <span className={`acpmux-picker acpmux-context${full}`}>
      <button
        ref={trigger}
        type="button"
        className="acpmux-context-ring"
        data-menu={t("context.title")}
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        onPointerDown={() => (openAtPress.current = open)}
        onClick={() => {
          setOpen(!(openAtPress.current ?? open));
          openAtPress.current = null;
        }}
      >
        <svg width={16} height={16} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
          <circle cx="8" cy="8" r={radius} fill="none" stroke="currentColor" strokeOpacity={0.28} strokeWidth={2} />
          {fraction > 0 && (
            <circle
              cx="8"
              cy="8"
              r={radius}
              fill="none"
              stroke="currentColor"
              strokeWidth={2}
              strokeLinecap="round"
              strokeDasharray={`${circumference * fraction} ${circumference}`}
              transform="rotate(-90 8 8)"
            />
          )}
        </svg>
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={open ? trigger.current : null}
        label={t("context.title")}
        className={`acpmux-context-pop${full}`}
        finalFocus={trigger}
      >
        <div className="acpmux-context-title">{t("context.title")}</div>
        <div className="acpmux-context-percent">{t("context.percent", { percent })}</div>
        <div className="acpmux-context-bar" aria-hidden="true">
          <span style={{ width: `${percent}%` }} />
        </div>
        {known && (
          <div className="acpmux-context-tokens">
            {t("context.tokens", { used: tokens.format(used), size: tokens.format(size) })}
          </div>
        )}
        {onCompact && (
          <button
            type="button"
            className="acpmux-context-compact"
            disabled={working}
            onClick={() => {
              setOpen(false);
              onCompact();
            }}
          >
            {t("context.compact")}
          </button>
        )}
      </Popover>
    </span>
  );
}

/// Modes that skip approvals (such as "Full access") draw in the theme's warning color.
export function unrestricted(modeId: string): boolean {
  return /bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(modeId);
}

/// A pick that returns "keep" leaves the menu open (e.g. a row that expands the menu).
export type Section = { title?: string; choices: Choice[]; current?: string; onPick(id: string): void | "keep" };

/// A button that opens a menu above the composer: a select-only combobox, so
/// focus stays on the button, which names the active option. Each section is
/// a group with a check on its current choice; arrows move, Enter, Space or a
/// click picks, and Escape, a click elsewhere or focus leaving the pane closes.
export function Picker({
  label,
  className,
  button,
  sections,
  align,
  warnUnrestricted = false,
  returnFocus = true,
  heading,
}: {
  label: string;
  className: string;
  button: React.ReactNode;
  sections: Section[];
  align: "start" | "end";
  warnUnrestricted?: boolean;
  /// An action menu hands focus to whatever its pick focuses, not back to the button.
  returnFocus?: boolean;
  /// A question over the choices, as an approval menu asks it.
  heading?: string;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const menuId = useId();
  const menuStyle = useUiAnchor(trigger, menu, open, { side: "above", align: "start" });
  const rows = sections.flatMap((section, s) => section.choices.map((choice) => ({ section: s, choice })));
  // A live update can shrink the list under the highlight.
  const selected = Math.min(active, Math.max(rows.length - 1, 0));

  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => {
      document.removeEventListener("pointerdown", away);
      window.removeEventListener("blur", blur);
    };
  }, [open]);

  const show = () => {
    const current = rows.findIndex((row) => row.choice.id === sections[row.section].current);
    setActive(Math.max(current, 0));
    setOpen(true);
    // WebKit doesn't focus a clicked button; the keys must reach the menu, not the prompt.
    trigger.current?.focus();
  };
  const showRef = useRef(show);
  showRef.current = show;
  // Like a click, which takes focus off the prompt first: that closes the slash menu and restores the draft.
  useEffect(
    () =>
      registerPicker(label, () => {
        if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
        showRef.current();
      }),
    [label],
  );
  const close = () => {
    setOpen(false);
    trigger.current?.focus();
  };
  const press = usePopoverTrigger(open, setOpen, show);
  const pick = (index: number) => {
    const row = rows[index];
    if (!row) return;
    if (sections[row.section].onPick(row.choice.id) === "keep") return;
    if (returnFocus) close();
    else setOpen(false);
  };
  const keyDown = (event: React.KeyboardEvent) => {
    if (!open) {
      if (event.key === "ArrowUp" || event.key === "ArrowDown") {
        event.preventDefault();
        show();
      }
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      if (rows.length > 0) setActive((selected + step + rows.length) % rows.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(selected);
    }
    // A button clicks on Space's keyup; pick there and cancel that click, or it would reopen the menu.
    else if (event.key === " ") event.preventDefault();
    else if (event.key === "Tab") setOpen(false);
  };
  const keyUp = (event: React.KeyboardEvent) => {
    if (open && event.key === " ") {
      event.preventDefault();
      pick(selected);
    }
  };

  let index = -1;
  return (
    <span
      ref={root}
      className={`acpmux-picker ${className}`}
      style={{ position: "relative" }}
      onBlur={(event) => {
        if (open && !root.current?.contains(event.relatedTarget as Node | null)) setOpen(false);
      }}
    >
      <button
        ref={trigger}
        type="button"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="combobox"
        className="acpmux-picker-button"
        data-menu={label}
        aria-label={label}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-activedescendant={open && rows.length > 0 ? `${menuId}-${selected}` : undefined}
        onKeyDown={keyDown}
        onKeyUp={keyUp}
        {...press}
      >
        {button}
      </button>
      {/* A native select cannot hold descriptions, sections or the pane's styling. */}
      {open && (
        <div ref={menu} style={menuStyle} className={`acpmux-menu acpmux-menu-${align}`}>
          {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
          <div id={menuId} role="listbox" aria-label={heading ?? label}>
            {heading && (
              <div className="acpmux-menu-heading" aria-hidden="true">
                {heading}
              </div>
            )}
            {sections.map((section, s) => {
              const titled = section.title && sections.length > 1;
              return (
                <div
                  key={s}
                  className="acpmux-menu-section"
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                  role="group"
                  aria-labelledby={titled ? `${menuId}-group-${s}` : undefined}
                  aria-label={titled ? undefined : label}
                >
                  {titled && (
                    <div className="acpmux-menu-header" id={`${menuId}-group-${s}`}>
                      {section.title}
                    </div>
                  )}
                  {section.choices.map((choice) => {
                    index += 1;
                    const at = index;
                    const current = choice.id === section.current;
                    return (
                      <div
                        key={choice.id}
                        id={`${menuId}-${at}`}
                        data-value={choice.id}
                        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                        role="option"
                        tabIndex={-1}
                        aria-selected={at === selected}
                        aria-checked={section.current === undefined ? undefined : current}
                        className={`acpmux-menu-item${at === selected ? " acpmux-menu-active" : ""}${warnUnrestricted && unrestricted(choice.id) ? " acpmux-unrestricted" : ""}`}
                        onMouseMove={() => {
                          if (at !== selected) setActive(at);
                        }}
                        onMouseDown={(event) => {
                          event.preventDefault();
                          pick(at);
                        }}
                      >
                        {choice.icon}
                        <span className="acpmux-menu-text">
                          <span className="acpmux-menu-label">{choice.name}</span>
                          {choice.description && <span className="acpmux-menu-description">{choice.description}</span>}
                        </span>
                        {choice.hint && <kbd className="acpmux-menu-hint">{choice.hint}</kbd>}
                        {current && <CheckIcon />}
                      </div>
                    );
                  })}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </span>
  );
}

// Composer icons (a 16px grid drawn at 18px, stroke in currentColor).
function Icon({ children, size = 18 }: { children: React.ReactNode; size?: number }) {
  return (
    <svg
      className="acpmux-icon"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}
export const ShieldIcon = () => (
  <Icon>
    <path d="M8 1.9 13 3.7v4.1c0 3.1-2.3 5.3-5 6.3-2.7-1-5-3.2-5-6.3V3.7Z" />
    <path d="M8 5.2v3.3" />
    <circle cx="8" cy="10.9" r=".35" fill="currentColor" />
  </Icon>
);
export const LockIcon = () => (
  <Icon>
    <rect x="3.5" y="7" width="9" height="7" rx="1.5" />
    <path d="M5.5 7V5.6a2.5 2.5 0 0 1 5 0V7" />
  </Icon>
);
export const ChevronIcon = () => (
  <Icon size={14}>
    <path d="M4.6 6.3 8 9.6l3.4-3.3" />
  </Icon>
);
export const ChevronRightIcon = () => (
  <Icon>
    <path d="m6.25 4.25 3.5 3.75-3.5 3.75" />
  </Icon>
);
/// 16px in the model menu's search; the + menu draws it at its items' 18px.
export const SearchIcon = ({ size = 16 }: { size?: number }) => (
  <Icon size={size}>
    <circle cx="7" cy="7" r="4.25" />
    <path d="m10.25 10.25 3 3" />
  </Icon>
);
export const CheckIcon = () => (
  <Icon>
    <path d="M3 8.6 6.3 12 13 4.5" />
  </Icon>
);
export const PlusIcon = () => (
  <Icon>
    <path d="M8 2.75v10.5M2.75 8h10.5" />
  </Icon>
);
export const ArrowUpIcon = () => (
  <Icon>
    <path d="M8 13.4V2.8M3.4 7.3 8 2.7l4.6 4.6" />
  </Icon>
);
export const StopIcon = () => (
  <svg className="acpmux-icon" width={18} height={18} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
    <rect x="4.5" y="4.5" width="7" height="7" rx="1.5" fill="currentColor" />
  </svg>
);
export const PlanIcon = () => (
  <Icon>
    <path d="M5.5 4.25h7.25M5.5 8h7.25M5.5 11.75h7.25" />
    <circle cx="3" cy="4.25" r=".6" fill="currentColor" />
    <circle cx="3" cy="8" r=".6" fill="currentColor" />
    <circle cx="3" cy="11.75" r=".6" fill="currentColor" />
  </Icon>
);
export const BuildIcon = () => (
  <Icon>
    <path d="m9.6 3.2 3.2 3.2-6.9 6.9H2.7V10.1Z" />
    <path d="m8.2 4.6 3.2 3.2" />
  </Icon>
);
export const PaperclipIcon = () => (
  <Icon>
    <path d="m13.1 7.6-5 5a3.2 3.2 0 0 1-4.5-4.5l5.3-5.3a2.1 2.1 0 0 1 3 3L6.6 11a1.05 1.05 0 0 1-1.5-1.5L10 4.6" />
  </Icon>
);
export const AtIcon = () => (
  <Icon>
    <circle cx="8" cy="8" r="2.4" />
    <path d="M10.4 8v.9a1.8 1.8 0 0 0 3.6 0V8A6 6 0 1 0 11 13.2" />
  </Icon>
);
export const MicIcon = () => (
  <Icon>
    <rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" />
    <path d="M3 7.5a5 5 0 0 0 10 0M8 12.5V15" />
  </Icon>
);
export const SlashIcon = () => (
  <Icon>
    <path d="M10.5 2.5 5.5 13.5" />
  </Icon>
);
