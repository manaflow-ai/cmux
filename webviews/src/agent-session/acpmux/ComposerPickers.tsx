import React, { useEffect, useId, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { EffortPicker } from "./EffortPicker";
import { t } from "./i18n";

/// Picker copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const PICKER_LABELS = {
  model: "Model",
  mode: "Mode",
  effort: "Effort",
  plan: "Plan",
  build: "Build",
  planHint: "Plan reads and proposes without editing; Build makes the changes",
  /// `{percent}` is the share of the context window used.
  context: "{percent}% of context used",
};

export type Choice = { id: string; name: string; description?: string; icon?: React.ReactNode; hint?: string };

type Props = {
  snapshot: AcpmuxSnapshot;
  onModel(modelId: string): void;
  onMode(modeId: string): void;
  onEffort(configId: string, value: string): void;
};

/// The composer bar's controls, as Codex, Claude and T3 Code draw them: the
/// permission mode (in the warning color when it skips approvals) and a
/// Plan/Build toggle after the attach button, then the model and the effort as
/// two dropdowns and the context used at the right. Groups are set apart by a
/// hairline; each control shows only when the agent offers it.
export function ComposerPickers({ snapshot, onModel, onMode, onEffort }: Props) {
  const summary = snapshot.summary;
  const models: Choice[] = (snapshot.catalog.find((harness) => harness.id === summary?.harness)?.models ?? []).map(
    (model) => ({ id: model.id, name: model.name || model.id }),
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
  const efforts: Choice[] = (effort?.options ?? []).map((option) => ({
    id: option.value,
    name: option.name || option.value,
  }));
  const model = models.find((choice) => choice.id === summary?.model);
  const usage = summary?.usage;

  return (
    <div className="acpmux-chips">
      {modes.length > 0 && (
        <Picker
          label={PICKER_LABELS.mode}
          warnUnrestricted
          className={`acpmux-mode${mode && unrestricted(mode.id) ? " acpmux-unrestricted" : ""}`}
          button={
            <>
              <ShieldIcon />
              <span>{mode?.name ?? PICKER_LABELS.mode}</span>
              <ChevronIcon />
            </>
          }
          sections={[{ choices: modes, current: mode?.id, onPick: onMode }]}
          heading={t("approval.title")}
          align="start"
        />
      )}
      {plan && (
        <button
          type="button"
          className="acpmux-plan"
          aria-pressed={planning}
          title={PICKER_LABELS.planHint}
          onClick={() => onMode(planning ? (lastMode.current.mode ?? modes[0]?.id ?? plan.id) : plan.id)}
        >
          {planning ? <PlanIcon /> : <BuildIcon />}
          <span>{planning ? PICKER_LABELS.plan : PICKER_LABELS.build}</span>
        </button>
      )}
      <span className="acpmux-chips-spacer" />
      {models.length > 0 && (
        <Picker
          label={PICKER_LABELS.model}
          className="acpmux-model"
          button={
            <>
              <span className="acpmux-model-name">{model?.name ?? summary?.model ?? PICKER_LABELS.model}</span>
              <ChevronIcon />
            </>
          }
          sections={[{ choices: models, current: model?.id, onPick: onModel }]}
          align="end"
        />
      )}
      {effort && efforts.length > 0 && (
        <EffortPicker
          efforts={efforts}
          current={effort.currentValue}
          model={model?.name ?? summary?.model}
          chevron={<ChevronIcon />}
          onPick={(value) => onEffort(effort.id, value)}
        />
      )}
      {usage && usage.size > 0 && <ContextRing used={usage.used} size={usage.size} />}
      {(models.length > 0 || efforts.length > 0 || usage) && <span className="acpmux-separator" aria-hidden="true" />}
    </div>
  );
}

/// Plan modes (Claude's "plan") read and propose without editing; the toggle sits apart from the permission chip.
export function isPlan(modeId: string): boolean {
  return /(^|[-_])plan$/i.test(modeId);
}

/// How much of the context window the session has used, as Claude draws it: a ring that fills.
export function ContextRing({ used, size }: { used: number; size: number }) {
  const fraction = Math.min(1, Math.max(0, used / size));
  const percent = Math.round(fraction * 100);
  const label = PICKER_LABELS.context.replace("{percent}", String(percent));
  const radius = 7;
  const circumference = 2 * Math.PI * radius;
  return (
    <span
      className={`acpmux-context-ring${fraction >= 0.8 ? " acpmux-context-full" : ""}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="img"
      aria-label={label}
      title={label}
    >
      <svg width={18} height={18} viewBox="0 0 18 18" aria-hidden="true" focusable="false">
        <circle cx="9" cy="9" r={radius} fill="none" stroke="currentColor" strokeOpacity={0.28} strokeWidth={2} />
        {fraction > 0 && (
          <circle
            cx="9"
            cy="9"
            r={radius}
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            strokeLinecap="round"
            strokeDasharray={`${circumference * fraction} ${circumference}`}
            transform="rotate(-90 9 9)"
          />
        )}
      </svg>
    </span>
  );
}

/// Modes that skip approvals draw in the theme's warning color, as Codex draws "Full access".
export function unrestricted(modeId: string): boolean {
  return /bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(modeId);
}

export type Section = { title?: string; choices: Choice[]; current?: string; onPick(id: string): void };

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
  /// A question over the choices, as Codex's approval menu asks it.
  heading?: string;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menuId = useId();
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
  const close = () => {
    setOpen(false);
    trigger.current?.focus();
  };
  const pick = (index: number) => {
    const row = rows[index];
    if (!row) return;
    if (returnFocus) close();
    else setOpen(false);
    sections[row.section].onPick(row.choice.id);
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
      setActive((selected + step + rows.length) % rows.length);
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
        aria-label={label}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-activedescendant={open ? `${menuId}-${selected}` : undefined}
        onKeyDown={keyDown}
        onKeyUp={keyUp}
        onClick={() => (open ? setOpen(false) : show())}
      >
        {button}
      </button>
      {/* A native select cannot hold descriptions, sections or the Codex look. */}
      {open && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className={`acpmux-menu acpmux-menu-${align}`} id={menuId} role="listbox" aria-label={heading ?? label}>
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
      )}
    </span>
  );
}

// Icons from the Codex chrome (a 16px grid drawn at 18px, stroke in currentColor).
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
export const ChevronIcon = () => (
  <Icon size={14}>
    <path d="M4.6 6.3 8 9.6l3.4-3.3" />
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
export const SlashIcon = () => (
  <Icon>
    <path d="M10.5 2.5 5.5 13.5" />
  </Icon>
);
