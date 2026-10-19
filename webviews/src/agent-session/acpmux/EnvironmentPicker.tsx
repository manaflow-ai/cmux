import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { translate as t } from "./i18n";
import {
  type Environment,
  type EnvironmentKind,
  environmentDigit,
  environmentForDigit,
  orderEnvironments,
} from "./environments";
import { useLocationOpener, useLocationPopover } from "./locationPopover";

const SECTION_LABELS = {
  local: "composer.envLocal",
  ssh: "composer.envSSH",
  cloud: "composer.cloud",
} as const;

/// The environment picker (preview, `labs.previewFeatures`): one searchable list with Local, SSH
/// and Cloud sections, ⌥⌘1–9 on the first nine, and New environment at the bottom: the host's SSH…
/// and cmux Cloud… connect flows. ⌥⌘1–9 also work while the composer it heads has focus.
export function EnvironmentPicker({
  label,
  menu,
  value,
  face,
  environments,
  current,
  onPick,
  onConnect,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  /// The current environment's name: the control's accessible name and tooltip carry it, since a
  /// narrow strip shows its icon alone.
  value: string;
  face: React.ReactNode;
  environments: Environment[];
  current: string;
  onPick(id: string): void;
  onConnect?(kind: "ssh" | "cloud"): void;
}) {
  const [query, setQuery] = useState("");
  const trigger = useRef<HTMLButtonElement>(null);
  const escaped = useRef(false);
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const reset = () => {
    setQuery("");
  };
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) reset();
  });
  useLocationOpener(menu, () => setOpen(true));
  const ordered = useMemo(() => orderEnvironments(environments), [environments]);
  const numbers = useMemo(
    () => new Map(ordered.slice(0, 9).map((environment, index) => [environment.id, index + 1])),
    [ordered],
  );
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return ordered.filter((environment) => {
      const text = `${environment.label} ${t(SECTION_LABELS[environment.kind])}`.toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [ordered, query]);
  // New environment, last: the host's two connect flows under one heading.
  const actions: { value: string; text: string; kind: "ssh" | "cloud"; run(): void }[] = onConnect
    ? [
        { value: ACTION + "ssh", text: t("composer.connectSSH"), kind: "ssh", run: () => onConnect("ssh") },
        { value: ACTION + "cloud", text: t("composer.connectCloud"), kind: "cloud", run: () => onConnect("cloud") },
      ]
    : [];
  const suggestions = [...shown.map((environment) => environment.id), ...actions.map((action) => action.value)];

  const latest = useRef({ ordered, current, onPick });
  latest.current = { ordered, current, onPick };
  const close = () => {
    setOpen(false);
    reset();
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const closeRef = useRef(close);
  closeRef.current = close;
  // ⌥⌘1–9: while the list is open, or while focus is in the composer this picker heads.
  const openRef = useRef(open);
  openRef.current = open;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const digit = environmentDigit(event);
      if (digit === undefined) return;
      const scope = control.current?.closest(".acpmux-composer, .nt-composer");
      const active = document.activeElement;
      if (!openRef.current && !(scope && active && scope.contains(active))) return;
      const environment = environmentForDigit(latest.current.ordered, digit);
      // A digit that changes nothing in a closed picker stays the app's (a keymap may bind ⌥⌘1–9).
      if (!environment || (!openRef.current && environment.id === latest.current.current)) return;
      event.preventDefault();
      event.stopPropagation();
      if (openRef.current) closeRef.current();
      if (environment.id !== latest.current.current) latest.current.onPick(environment.id);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [control]);

  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    close();
    if (action) action.run();
    else if (value !== current && shown.some((environment) => environment.id === value)) onPick(value);
  };
  const row = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-section={action === actions[0] ? t("composer.newEnvironment") : undefined}
        >
          <EnvironmentIcon kind={action.kind} />
          <span className="acpmux-menu-label">{action.text}</span>
        </span>
      );
    const environment = shown.find((candidate) => candidate.id === value);
    if (!environment) return null;
    const index = shown.indexOf(environment);
    const sectionStart = index === 0 || shown[index - 1]!.kind !== environment.kind;
    const number = numbers.get(environment.id);
    return (
      <span
        className="acpmux-location-row acpmux-env-row"
        data-kind={environment.kind}
        data-section={sectionStart ? t(SECTION_LABELS[environment.kind]) : undefined}
        data-first-section={sectionStart && index === 0 ? "" : undefined}
        data-current={environment.id === current ? "" : undefined}
      >
        <EnvironmentIcon kind={environment.kind} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{environment.label}</span>
        </span>
        {number !== undefined && <kbd className="acpmux-env-key">⌥⌘{number}</kbd>}
        <span className="acpmux-location-check" aria-hidden="true">
          {environment.id === current && <CheckIcon />}
        </span>
      </span>
    );
  };

  return (
    // tooltip-allow: at or under a 460 px pane the environment shows only its icon; the tooltip names it
    <span ref={control} className="acpmux-location-picker" data-kind="computer" title={label + ": " + value}>
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        aria-label={label + ": " + value}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {face}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) reset();
        }}
        anchor={open ? anchor : null}
        label={label}
        className="acpmux-menu acpmux-location-menu acpmux-folder-popover acpmux-env-popover"
        side={side}
        flip={false}
        finalFocus={false}
      >
        <Combobox
          suggestions={suggestions}
          onQuery={setQuery}
          onSubmit={submit}
          onCancel={close}
          onCommand={(event) => {
            if (event.key === "Escape") escaped.current = true;
            if (event.key === "Tab") event.preventDefault();
          }}
          label={t("composer.environmentSearch")}
          placeholder={t("composer.environmentSearch")}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          renderItem={row}
          autoHighlight
          inline
        />
        {query.trim() !== "" && shown.length === 0 && (
          <div className="acpmux-location-empty">{t("composer.environmentNone")}</div>
        )}
      </Popover>
    </span>
  );
}

/// An action row's value: never a machine's id.
const ACTION = "\u0000action:";

export function EnvironmentIcon({ kind }: { kind: EnvironmentKind }) {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind={kind}
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {kind === "local" ? (
        <>
          <rect x="3" y="3.5" width="10" height="7" rx="1.2" />
          <path d="M1.75 12.5h12.5" />
        </>
      ) : kind === "ssh" ? (
        <>
          <rect x="2" y="3" width="12" height="10" rx="1.5" />
          <path d="m4.75 6.5 2 1.75-2 1.75M8.5 10h2.75" />
        </>
      ) : (
        <path d="M4.6 12.5h7a2.6 2.6 0 0 0 .4-5.17A3.6 3.6 0 0 0 5.1 6.2 3.15 3.15 0 0 0 4.6 12.5Z" />
      )}
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m3.5 8.5 3 3 6-7" />
    </svg>
  );
}
