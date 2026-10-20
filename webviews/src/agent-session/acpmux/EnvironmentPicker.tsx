import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { translate as t } from "./i18n";
import {
  type Environment,
  type EnvironmentKind,
  type SavedEnvironment,
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

/// The New Tab page's saved environments in the picker: a Saved section over the machines, Create
/// environment under New environment, and Edit environment while one is picked.
export type SavedEnvironmentRows = {
  environments: readonly SavedEnvironment[];
  /// The picked one's id: it, not a machine, is the current row.
  current?: string;
  onPick(id: string): void;
  /// A machine was picked instead: no saved environment is.
  onClear(): void;
  onCreate(): void;
  onEdit(id: string): void;
};

/// The environment picker (preview, `labs.previewFeatures`): one searchable list with Local, SSH
/// and Cloud sections, ⌥⌘1–9 on the first nine, and New environment at the bottom: the host's SSH…
/// and cmux Cloud… connect flows. ⌥⌘1–9 also work while the composer it heads has focus. On the
/// New Tab page it also lists the saved environments (`saved`) first.
export function EnvironmentPicker({
  label,
  menu,
  value,
  face,
  environments,
  current,
  onPick,
  onConnect,
  saved,
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
  saved?: SavedEnvironmentRows;
}) {
  // A picked saved environment is the current row: every machine row is then a change.
  const currentRow = saved?.current !== undefined ? SAVED + saved.current : current;
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
  const words = useMemo(() => query.trim().toLowerCase().split(/\s+/).filter(Boolean), [query]);
  const shown = useMemo(
    () =>
      ordered.filter((environment) => matches(words, `${environment.label} ${t(SECTION_LABELS[environment.kind])}`)),
    [ordered, words],
  );
  // The saved environments, first, by name and the Saved section's name.
  const savedShown = useMemo(
    () =>
      (saved?.environments ?? []).filter((environment) =>
        matches(words, `${environment.name} ${t("composer.envSaved")}`),
      ),
    [saved?.environments, words],
  );
  // Each shown row's environment and place, so a row reads its section without rescanning the list.
  const positions = useMemo(
    () =>
      new Map(
        shown.map((environment, index) => [
          environment.id,
          { environment, index, sectionStart: index === 0 || shown[index - 1]!.kind !== environment.kind },
        ]),
      ),
    [shown],
  );
  // New environment, last: Create environment (the New Tab page's saved ones) and the host's two
  // connect flows under one heading; Edit environment while a saved one is picked.
  const editing = saved?.current;
  const actions: { value: string; text: string; icon: React.ReactNode; run(): void }[] = [
    ...(saved
      ? [
          {
            value: ACTION + "create",
            text: t("environment.create"),
            icon: <PlusIcon />,
            run: saved.onCreate,
          },
        ]
      : []),
    ...(saved && editing !== undefined
      ? [
          {
            value: ACTION + "edit",
            text: t("environment.edit"),
            icon: <PencilIcon />,
            run: () => saved.onEdit(editing),
          },
        ]
      : []),
    ...(onConnect
      ? [
          {
            value: ACTION + "ssh",
            text: t("composer.connectSSH"),
            icon: <EnvironmentIcon kind="ssh" />,
            run: () => onConnect("ssh"),
          },
          {
            value: ACTION + "cloud",
            text: t("composer.connectCloud"),
            icon: <EnvironmentIcon kind="cloud" />,
            run: () => onConnect("cloud"),
          },
        ]
      : []),
  ];
  const suggestions = [
    ...savedShown.map((environment) => SAVED + environment.id),
    ...shown.map((environment) => environment.id),
    ...actions.map((action) => action.value),
  ];

  const latest = useRef({ ordered, current: currentRow, onPick });
  latest.current = { ordered, current: currentRow, onPick };
  const close = () => {
    setOpen(false);
    reset();
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  // Picking the environment already chosen changes nothing, so no caller moves focus: the prompt
  // this picker heads takes it back.
  const focusPrompt = () => {
    const scope = control.current?.closest(".acpmux-composer, .nt-composer");
    scope?.querySelector<HTMLElement>("textarea, [contenteditable='true']")?.focus();
  };
  const focusPromptRef = useRef(focusPrompt);
  focusPromptRef.current = focusPrompt;
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
      else focusPromptRef.current();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [control]);

  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    close();
    if (action) action.run();
    else if (value === currentRow) focusPrompt();
    else if (value.startsWith(SAVED)) saved?.onPick(value.slice(SAVED.length));
    else if (positions.has(value)) onPick(value);
  };
  const row = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-section={action === actions[0] ? t("composer.newEnvironment") : undefined}
        >
          {action.icon}
          <span className="acpmux-menu-label">{action.text}</span>
        </span>
      );
    if (value.startsWith(SAVED)) {
      const index = savedShown.findIndex((environment) => SAVED + environment.id === value);
      const environment = savedShown[index];
      if (!environment) return null;
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-saved"
          data-kind={environment.kind}
          data-section={index === 0 ? t("composer.envSaved") : undefined}
          data-first-section={index === 0 ? "" : undefined}
          data-current={value === currentRow ? "" : undefined}
        >
          <EnvironmentIcon kind={environment.kind} />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{environment.name}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {value === currentRow && <CheckIcon />}
          </span>
        </span>
      );
    }
    const position = positions.get(value);
    if (!position) return null;
    const { environment, index, sectionStart } = position;
    const number = numbers.get(environment.id);
    return (
      <span
        className="acpmux-location-row acpmux-env-row"
        data-kind={environment.kind}
        data-section={sectionStart ? t(SECTION_LABELS[environment.kind]) : undefined}
        data-first-section={sectionStart && index === 0 && savedShown.length === 0 ? "" : undefined}
        data-current={environment.id === currentRow ? "" : undefined}
      >
        <EnvironmentIcon kind={environment.kind} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{environment.label}</span>
        </span>
        {number !== undefined && <kbd className="acpmux-env-key">⌥⌘{number}</kbd>}
        <span className="acpmux-location-check" aria-hidden="true">
          {environment.id === currentRow && <CheckIcon />}
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
        {query.trim() !== "" && shown.length === 0 && savedShown.length === 0 && (
          <div className="acpmux-location-empty">{t("composer.environmentNone")}</div>
        )}
      </Popover>
    </span>
  );
}

/// An action row's value: never a machine's id.
const ACTION = "\u0000action:";
/// A saved environment's row value: its id after this, never a machine's id.
const SAVED = "\u0000saved:";

/// Whether every search word is in `text`.
function matches(words: readonly string[], text: string): boolean {
  const lower = text.toLowerCase();
  return words.every((word) => lower.includes(word));
}

function PlusIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M8 3.5v9M3.5 8h9" />
    </svg>
  );
}

function PencilIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
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
      <path d="M10.5 3.5 12.5 5.5 6 12H4v-2l6.5-6.5Z" />
    </svg>
  );
}

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
