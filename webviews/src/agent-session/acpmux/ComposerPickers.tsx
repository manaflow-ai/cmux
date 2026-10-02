import React, { useEffect, useId, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";

/// Picker copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const PICKER_LABELS = {
  model: "Model",
  mode: "Mode",
  effort: "Effort",
};

type Choice = { id: string; name: string; description?: string };

type Props = {
  snapshot: AcpmuxSnapshot;
  onModel(modelId: string): void;
  onMode(modeId: string): void;
  onEffort(configId: string, value: string): void;
};

/// The composer bar's pickers, drawn like Codex's: the session mode as a chip
/// after the attach slot, and the model with its effort at the right. Each
/// shows only when the agent offers a choice.
export function ComposerPickers({ snapshot, onModel, onMode, onEffort }: Props) {
  const summary = snapshot.summary;
  const models: Choice[] = (snapshot.catalog.find((harness) => harness.id === summary?.harness)?.models ?? []).map((model) => ({ id: model.id, name: model.name || model.id }));
  const modes: Choice[] = (summary?.modes?.availableModes ?? []).map((mode) => ({ id: mode.id, name: mode.name || mode.id, description: mode.description }));
  const effort = summary?.configOptions?.find((option) => option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort");
  const efforts: Choice[] = (effort?.options ?? []).map((option) => ({ id: option.value, name: option.name || option.value }));
  const mode = modes.find((choice) => choice.id === summary?.modes?.currentModeId);
  const model = models.find((choice) => choice.id === summary?.model);
  const effortName = efforts.find((choice) => choice.id === effort?.currentValue)?.name;

  return <div className="acpmux-chips">
    {modes.length > 0 && <Picker label={PICKER_LABELS.mode} warnUnrestricted className={`acpmux-mode${mode && unrestricted(mode.id) ? " acpmux-unrestricted" : ""}`}
      button={<><ShieldIcon /><span>{mode?.name ?? PICKER_LABELS.mode}</span></>}
      sections={[{ choices: modes, current: mode?.id, onPick: onMode }]} align="start" />}
    <span className="acpmux-chips-spacer" />
    {(models.length > 0 || efforts.length > 0) && <Picker label={PICKER_LABELS.model} className="acpmux-model"
      button={<><span className="acpmux-model-name">{model?.name ?? summary?.model ?? (models.length > 0 ? PICKER_LABELS.model : "")}</span>{effortName && <span className="acpmux-model-effort">{effortName}</span>}<ChevronIcon /></>}
      sections={[
        ...(models.length > 0 ? [{ title: PICKER_LABELS.model, choices: models, current: model?.id, onPick: onModel }] : []),
        ...(effort && efforts.length > 0 ? [{ title: PICKER_LABELS.effort, choices: efforts, current: effort.currentValue, onPick: (value: string) => onEffort(effort.id, value) }] : []),
      ]} align="end" />}
  </div>;
}

/// Modes that skip approvals draw in the theme's warning color, as Codex draws "Full access".
export function unrestricted(modeId: string): boolean {
  return /bypass|full|yolo|dangerous|auto[-_ ]?approve/i.test(modeId);
}

type Section = { title?: string; choices: Choice[]; current?: string; onPick(id: string): void };

/// A button that opens a menu above the composer: a select-only combobox, so
/// focus stays on the button, which names the active option. Each section is
/// a group with a check on its current choice; arrows move, Enter, Space or a
/// click picks, and Escape, a click elsewhere or focus leaving the pane closes.
function Picker({ label, className, button, sections, align, warnUnrestricted = false }: { label: string; className: string; button: React.ReactNode; sections: Section[]; align: "start" | "end"; warnUnrestricted?: boolean }) {
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
    const away = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const blur = () => setOpen(false);
    document.addEventListener("pointerdown", away);
    window.addEventListener("blur", blur);
    return () => { document.removeEventListener("pointerdown", away); window.removeEventListener("blur", blur); };
  }, [open]);

  const show = () => {
    const current = rows.findIndex((row) => row.choice.id === sections[row.section].current);
    setActive(Math.max(current, 0));
    setOpen(true);
    // WebKit doesn't focus a clicked button; the keys must reach the menu, not the prompt.
    trigger.current?.focus();
  };
  const close = () => { setOpen(false); trigger.current?.focus(); };
  const pick = (index: number) => {
    const row = rows[index];
    if (!row) return;
    sections[row.section].onPick(row.choice.id);
    close();
  };
  const keyDown = (event: React.KeyboardEvent) => {
    if (!open) {
      if (event.key === "ArrowUp" || event.key === "ArrowDown") { event.preventDefault(); show(); }
      return;
    }
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); }
    else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive((selected + step + rows.length) % rows.length);
    } else if (event.key === "Enter") { event.preventDefault(); pick(selected); }
    // A button clicks on Space's keyup; pick there and cancel that click, or it would reopen the menu.
    else if (event.key === " ") event.preventDefault();
    else if (event.key === "Tab") setOpen(false);
  };
  const keyUp = (event: React.KeyboardEvent) => {
    if (open && event.key === " ") { event.preventDefault(); pick(selected); }
  };

  let index = -1;
  return <span ref={root} className={`acpmux-picker ${className}`}
    onBlur={(event) => { if (open && !root.current?.contains(event.relatedTarget as Node | null)) setOpen(false); }}>
    {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
    <button ref={trigger} type="button" role="combobox" className="acpmux-picker-button" aria-label={label} aria-haspopup="listbox" aria-expanded={open}
      aria-controls={open ? menuId : undefined} aria-activedescendant={open ? `${menuId}-${selected}` : undefined}
      onKeyDown={keyDown} onKeyUp={keyUp} onClick={() => open ? setOpen(false) : show()}>{button}</button>
    {/* A native select cannot hold descriptions, sections or the Codex look. */}
    {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
    {open && <div className={`acpmux-menu acpmux-menu-${align}`} id={menuId} role="listbox" aria-label={label}>
      {sections.map((section, s) => {
        const titled = section.title && sections.length > 1;
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        return <div key={s} className="acpmux-menu-section" role="group" aria-labelledby={titled ? `${menuId}-group-${s}` : undefined} aria-label={titled ? undefined : label}>
          {titled && <div className="acpmux-menu-header" id={`${menuId}-group-${s}`}>{section.title}</div>}
          {section.choices.map((choice) => {
            index += 1;
            const at = index;
            const current = choice.id === section.current;
            return <div key={choice.id} id={`${menuId}-${at}`} data-value={choice.id}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option" tabIndex={-1} aria-selected={at === selected} aria-checked={current}
              className={`acpmux-menu-item${at === selected ? " acpmux-menu-active" : ""}${warnUnrestricted && unrestricted(choice.id) ? " acpmux-unrestricted" : ""}`}
              onMouseMove={() => { if (at !== selected) setActive(at); }} onMouseDown={(event) => { event.preventDefault(); pick(at); }}>
              <span className="acpmux-menu-text"><span className="acpmux-menu-label">{choice.name}</span>{choice.description && <span className="acpmux-menu-description">{choice.description}</span>}</span>
              {current && <CheckIcon />}
            </div>;
          })}
        </div>;
      })}
    </div>}
  </span>;
}

// Icons from the Codex chrome (16px box, stroke in currentColor).
function Icon({ children, size = 16 }: { children: React.ReactNode; size?: number }) {
  return <svg className="acpmux-icon" width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={1.25} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">{children}</svg>;
}
export const ShieldIcon = () => <Icon><path d="M8 1.9 13 3.7v4.1c0 3.1-2.3 5.3-5 6.3-2.7-1-5-3.2-5-6.3V3.7Z" /><path d="M8 5.2v3.3" /><circle cx="8" cy="10.9" r=".35" fill="currentColor" /></Icon>;
export const ChevronIcon = () => <Icon size={14}><path d="M4.6 6.3 8 9.6l3.4-3.3" /></Icon>;
export const CheckIcon = () => <Icon><path d="M3 8.6 6.3 12 13 4.5" /></Icon>;
export const PlusIcon = () => <Icon><path d="M8 2.75v10.5M2.75 8h10.5" /></Icon>;
export const ArrowUpIcon = () => <Icon><path d="M8 13.4V2.8M3.4 7.3 8 2.7l4.6 4.6" /></Icon>;
export const StopIcon = () => <svg className="acpmux-icon" width={16} height={16} viewBox="0 0 16 16" aria-hidden="true" focusable="false"><rect x="4.5" y="4.5" width="7" height="7" rx="1.5" fill="currentColor" /></svg>;
