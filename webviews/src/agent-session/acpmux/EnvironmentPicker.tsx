import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { translate as t, type StringKey } from "./i18n";
import {
  type ConnectKind,
  type Environment,
  type EnvironmentKind,
  type OffloadKind,
  type EnvironmentSection,
  type SavedEnvironment,
  environmentDigit,
  environmentForDigit,
  environmentReady,
  environmentSections,
  numberedEnvironments,
  orderEnvironments,
} from "./environments";
import { type CloudMachine, isCloudMachineRow } from "./cloudMachines";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { machineColor } from "./machineColor";
import type { RunModeRows } from "./sandboxRun";

/// The sections (environments.ts `environmentSections`): This Mac, My machines, Cloud and VMs.
export const SECTION_LABELS: Record<EnvironmentSection, StringKey> = {
  local: "composer.thisMac",
  mine: "composer.envMine",
  fleet: "composer.envFleet",
};
/// A machine's kind, which the search also matches ("ssh", "cloud").
const KIND_LABELS: Record<EnvironmentKind, StringKey> = {
  local: "composer.envLocal",
  ssh: "composer.envSSH",
  cloud: "composer.cloud",
};
/// A machine a chat cannot start on yet, in words: its link state as acpmux says it.
const STATE_LABELS: Record<string, StringKey> = {
  connecting: "rail.connectorPending",
  degraded: "rail.connectorPending",
  reconnecting: "header.reconnecting",
};
export function environmentStateLabel(environment: Environment): string {
  if (isCloudMachineRow(environment)) return cloudMachineLabel(environment.cloudMachine);
  return t(STATE_LABELS[environment.state ?? ""] ?? "composer.envNotConnected");
}
/// An account Cloud machine acpmux does not list (cloudMachines.ts): its stage, and what a pick does.
const CLOUD_STAGE_LABELS: Record<string, StringKey> = {
  ready: "composer.envOpenMachine",
  paused: "composer.envPausedResume",
  requesting: "composer.envStarting",
  creating: "composer.envStarting",
  booting: "composer.envStarting",
  connecting: "composer.envStarting",
};
function cloudMachineLabel(machine: CloudMachine): string {
  return t(CLOUD_STAGE_LABELS[machine.stage] ?? "composer.envNotConnected");
}

/// How often an open machine list reads the machines again: acpmux sends no peer events, so a
/// machine that connects or drops while the list is open shows within this long.
export const MACHINES_REFRESH_MS = 5_000;

/// While a machine list is open, `refresh` runs as it opens and then every MACHINES_REFRESH_MS;
/// the timer stops when the list closes or the picker unmounts.
export function useMachineRefresh(open: boolean, refresh: (() => void) | undefined): void {
  const latest = useRef(refresh);
  latest.current = refresh;
  useEffect(() => {
    if (!open) return;
    latest.current?.();
    const timer = setInterval(() => latest.current?.(), MACHINES_REFRESH_MS);
    return () => clearInterval(timer);
  }, [open]);
}

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

/// The environment picker (preview, `labs.previewFeatures`): one searchable list of every machine
/// acpmux lists, in This Mac, My machines and Cloud and VMs sections (environments.ts), the ones a
/// chat can start on first and the rest greyed with their state; ⌥⌘1–9 on the first nine that can
/// take a chat. Cloud is always a section: its machines, then New
/// Cloud Machine (the host's create flow) with what one gives, so a cloud machine is one click away
/// even before the first. New environment at the bottom holds the SSH… connect flow. ⌥⌘1–9 also
/// work while the composer it heads has focus. On the New Tab page it also lists the saved
/// environments (`saved`) first. A started chat's picker lists only where it runs and its move
/// (`offload`): Move to Cloud from this Mac, Bring Back Local from a Cloud machine. A new chat with
/// `runMode` (Labs, hq#3367) also offers Sandboxed as New Cloud Machine's other face, with no row of
/// its own: shown while ⌥ is held, while the search names it, and while it is the pick.
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
  onOpen,
  offload,
  onOffload,
  auto,
  runMode,
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
  onConnect?(kind: ConnectKind): void;
  saved?: SavedEnvironmentRows;
  /// The list opened, and every few seconds while it stays open: the host reads the machines
  /// again, so each one's status is current.
  onOpen?(): void;
  /// A started chat's move, run by `onOffload`.
  offload?: OffloadKind;
  onOffload?(kind: OffloadKind): void;
  /// A new chat's automatic destination. It stays at the top of the picker until an explicit row is picked.
  auto?: { detail: string; selected: boolean; onPick(): void };
  /// A new chat's Run as (preview, hq#3367): Persistent (a chat, as before) or Sandboxed (the
  /// first message runs once on a throwaway Cloud VM).
  runMode?: RunModeRows;
}) {
  // A picked saved environment is the current row: every machine row is then a change.
  const currentRow = auto?.selected ? ACTION + "auto" : saved?.current !== undefined ? SAVED + saved.current : current;
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
  // Sandboxed is the pick: no machine row is checked, and a machine pick goes back to Persistent.
  const sandboxed = runMode?.mode === "sandboxed";
  const checkedRow = sandboxed ? undefined : currentRow;
  const persistent = () => {
    if (sandboxed) runMode?.onMode("persistent");
  };
  // ⌥ held while the list is open shows New Cloud Machine's other face (as a Mac menu's alternate).
  // ⌥ already held as the trigger is pressed counts too: the press's own modifier state.
  const [alternate, setAlternate] = useState(false);
  const altAtPress = useRef(false);
  const offersSandbox = runMode !== undefined;
  useEffect(() => {
    if (!open || !offersSandbox) return;
    setAlternate(altAtPress.current);
    const onKey = (event: KeyboardEvent | PointerEvent) => setAlternate(event.altKey);
    const onBlur = () => setAlternate(false);
    // ui-allow: ⌥ shows a menu row's alternate while the list is open, as a Mac menu does.
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("keyup", onKey, true);
    window.addEventListener("pointermove", onKey, true);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("keyup", onKey, true);
      window.removeEventListener("pointermove", onKey, true);
      window.removeEventListener("blur", onBlur);
      altAtPress.current = false;
      setAlternate(false);
    };
  }, [open, offersSandbox]);
  const ordered = useMemo(() => orderEnvironments(environments), [environments]);
  const sections = useMemo(() => environmentSections(environments), [environments]);
  const sectionOf = (environment: Environment) => sections.get(environment.id) ?? "fleet";
  const numbers = useMemo(
    () => new Map(numberedEnvironments(environments).map((environment, index) => [environment.id, index + 1])),
    [environments],
  );
  const words = useMemo(() => query.trim().toLowerCase().split(/\s+/).filter(Boolean), [query]);
  const shown = useMemo(
    () =>
      ordered.filter((environment) =>
        matches(
          words,
          `${environment.label} ${t(SECTION_LABELS[sections.get(environment.id) ?? "fleet"])} ${t(KIND_LABELS[environment.kind])}`,
        ),
      ),
    [ordered, sections, words],
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
          {
            environment,
            index,
            sectionStart: index === 0 || sections.get(shown[index - 1]!.id) !== sections.get(environment.id),
          },
        ]),
      ),
    [shown, sections],
  );
  // New Cloud Machine and Open Cloud… close the Cloud section (New Cloud Machine heads the section
  // when there is no cloud machine); New environment, last: Create environment (the New Tab page's saved ones), Edit environment
  // while a saved one is picked, and the SSH connect flow.
  const editing = saved?.current;
  type Action = {
    value: string;
    text: string;
    detail?: string;
    kind: "auto" | "local" | "ssh" | "cloud" | "saved" | "phone";
    icon?: React.ReactNode;
    run(): void;
  };
  const actions: Action[] = [
    ...(auto
      ? [
          {
            value: ACTION + "auto",
            text: t("composer.auto"),
            detail: auto.detail,
            kind: "auto" as const,
            icon: <AutoIcon />,
            run: () => {
              persistent();
              auto.onPick();
            },
          },
        ]
      : []),
    ...(offload && onOffload
      ? [
          offload === "move"
            ? {
                value: ACTION + offload,
                text: t("composer.moveToCloud"),
                detail: t("composer.moveToCloudDetail"),
                kind: "cloud" as const,
                run: () => onOffload(offload),
              }
            : {
                value: ACTION + offload,
                text: t("composer.bringBackLocal"),
                detail: t("composer.bringBackLocalDetail"),
                kind: "local" as const,
                run: () => onOffload(offload),
              },
        ]
      : []),
    ...(onConnect
      ? [
          {
            value: ACTION + "cloud",
            text: t("composer.newCloudMachine"),
            detail: t("composer.newCloudMachineDetail"),
            kind: "cloud" as const,
            run: () => onConnect("cloud"),
          },
          {
            value: ACTION + "cloudPage",
            text: t("composer.openCloud"),
            kind: "cloud" as const,
            run: () => onConnect("cloudPage"),
          },
        ]
      : []),
    ...(saved
      ? [
          {
            value: ACTION + "create",
            text: t("environment.create"),
            kind: "saved" as const,
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
            kind: "saved" as const,
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
            kind: "ssh" as const,
            run: () => onConnect("ssh"),
          },
          // Connect Phone… opens the Mobile Pairing page: cmux on iPhone reaches this Mac.
          {
            value: ACTION + "phone",
            text: t("composer.connectPhone"),
            kind: "phone" as const,
            icon: <PhoneIcon />,
            run: () => onConnect("phone"),
          },
          // The list's last row: Add Device, where a machine on the tailnet or in ~/.ssh/config is
          // one Add away (its agent daemon installed and kept current), or a new Cloud VM.
          {
            value: ACTION + "addMachine",
            text: t("composer.addMachine"),
            kind: "ssh" as const,
            icon: <PlusIcon />,
            run: () => onConnect("addMachine"),
          },
        ]
      : []),
  ];
  const suggestions = [
    ...actions
      .filter((action) => action.kind === "auto")
      .filter((action) => matches(words, action.text))
      .map((action) => action.value),
    ...savedShown.map((environment) => SAVED + environment.id),
    ...shown.map((environment) => environment.id),
    ...actions.filter((action) => action.kind !== "auto").map((action) => action.value),
  ];
  const cloudShown = shown.some((environment) => sectionOf(environment) === "fleet");
  const localShown = shown.some((environment) => sectionOf(environment) === "local");
  const firstNew = actions.find(
    (action) => action.kind !== "auto" && action.kind !== "cloud" && action.kind !== "local",
  );
  // New Cloud Machine's row shows Sandboxed instead while ⌥ is held (or, once picked, until it is),
  // or while the search names Sandboxed.
  const sandboxFace =
    offersSandbox &&
    ((words.length > 0 && matches(words, `${t("composer.sandboxed")} ${t("composer.sandboxedDetail")} sandbox`)) ||
      sandboxed !== alternate);

  const latest = useRef({ ordered, current: checkedRow, onPick, persistent });
  latest.current = { ordered, current: checkedRow, onPick, persistent };
  useMachineRefresh(open, onOpen);
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
      latest.current.persistent();
      if (environment.id !== latest.current.current) latest.current.onPick(environment.id);
      else focusPromptRef.current();
    };
    // ui-allow: ⌥⌘1–9 pick an environment while the list is open or the composer has focus, like an app menu key.
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [control]);

  // The row Base UI highlighted by itself (reason "none"), not by the arrow keys or the pointer.
  const autoHighlighted = useRef<string | undefined>(undefined);
  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    // A machine still connecting or down is listed, greyed, in its place, but is no pick: the list
    // stays open.
    const machine = positions.get(value)?.environment;
    if (machine && !environmentReady(machine) && !isCloudMachineRow(machine)) return;
    close();
    if (value === ACTION + "cloud" && sandboxFace) {
      if (sandboxed) focusPrompt();
      else runMode?.onMode("sandboxed");
      return;
    }
    // A machine, or New Cloud Machine (⌥ shows it while Sandboxed is the pick): Persistent again.
    if (!action || value === ACTION + "cloud") persistent();
    if (action) action.run();
    else if (value === currentRow) focusPrompt();
    else if (value.startsWith(SAVED)) saved?.onPick(value.slice(SAVED.length));
    else if (machine) onPick(value);
  };
  const row = (value: string) => {
    if (value === ACTION + "cloud" && sandboxFace) {
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind="cloud"
          data-mode="sandboxed"
          data-section={!cloudShown && actions[0]?.value === value ? t(SECTION_LABELS.fleet) : undefined}
          data-current={sandboxed ? "" : undefined}
        >
          <EnvironmentIcon kind="cloud" />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.sandboxed")}</span>
            <span className="acpmux-env-detail">{t("composer.sandboxedDetail")}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {sandboxed && <CheckIcon />}
          </span>
        </span>
      );
    }
    const action = actions.find((candidate) => candidate.value === value);
    if (action) {
      // The cloud action heads its section only when no cloud machine does, as Bring Back Local
      // heads Local when this Mac isn't listed; the first other action heads New environment.
      const section =
        action.kind === "cloud"
          ? action === actions[0] && !cloudShown
            ? t(SECTION_LABELS.fleet)
            : undefined
          : action.kind === "local"
            ? localShown
              ? undefined
              : t(SECTION_LABELS.local)
            : action === firstNew
              ? t("composer.newEnvironment")
              : undefined;
      const first = section && savedShown.length === 0 && shown.length === 0 && action === actions[0];
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind={
            action.kind === "saved" || action.kind === "phone" || action.kind === "auto" ? undefined : action.kind
          }
          data-section={section}
          data-first-section={first ? "" : undefined}
        >
          {action.icon ?? (
            <EnvironmentIcon
              kind={
                action.kind === "saved" || action.kind === "phone" || action.kind === "auto" ? "local" : action.kind
              }
            />
          )}
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{action.text}</span>
            {action.detail && (
              <span className="acpmux-env-detail">
                {action.kind === "auto" ? " · " : ""}
                {action.detail}
              </span>
            )}
          </span>
        </span>
      );
    }
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
          data-current={value === checkedRow ? "" : undefined}
        >
          <EnvironmentIcon kind={environment.kind} />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{environment.name}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {value === checkedRow && <CheckIcon />}
          </span>
        </span>
      );
    }
    const position = positions.get(value);
    if (!position) return null;
    const { environment, index, sectionStart } = position;
    const number = numbers.get(environment.id);
    const ready = environmentReady(environment);
    // An account Cloud machine acpmux does not list is a pick (it resumes or opens), not greyed.
    const greyed = !ready && !isCloudMachineRow(environment);
    return (
      <span
        className="acpmux-location-row acpmux-env-row"
        data-kind={environment.kind}
        data-section={sectionStart ? t(SECTION_LABELS[sectionOf(environment)]) : undefined}
        data-first-section={sectionStart && index === 0 && savedShown.length === 0 ? "" : undefined}
        data-current={environment.id === checkedRow ? "" : undefined}
        data-ready={greyed ? "false" : undefined}
        aria-disabled={greyed ? true : undefined}
      >
        <EnvironmentIcon kind={environment.kind} name={environment.label} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{environment.label}</span>
        </span>
        {/* A machine a chat cannot start on yet says why, greyed; one that can shows a status dot.
            Only an SSH or Cloud machine acpmux lists has a status; this Mac never shows one. */}
        {!ready && <span className="acpmux-env-state">{environmentStateLabel(environment)}</span>}
        {ready && environment.kind !== "local" && environment.connected !== undefined && (
          <span className="acpmux-env-status" data-connected={String(environment.connected)}>
            <span className="acpmux-env-status-text">
              {t(environment.connected ? "composer.envConnected" : "composer.envNotConnected")}
            </span>
          </span>
        )}
        {number !== undefined && <kbd className="acpmux-env-key">⌥⌘{number}</kbd>}
        <span className="acpmux-location-check" aria-hidden="true">
          {environment.id === checkedRow && <CheckIcon />}
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
        onPointerDown={(event) => {
          altAtPress.current = event.altKey;
          press.onPointerDown(event);
        }}
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
            // Return runs an action (New Cloud Machine creates a machine; Move to Cloud moves the
            // chat; Open Cloud…, SSH…) only
            // once the arrow keys or the pointer reached it, never when Base UI highlighted it on its
            // own: a search that leaves no machine moves that highlight onto the first action.
            if (
              event.key === "Enter" &&
              autoHighlighted.current?.startsWith(ACTION) &&
              autoHighlighted.current !== ACTION + "auto"
            ) {
              event.preventDefault();
              event.preventBaseUIHandler?.();
            }
          }}
          onHighlight={(value, by) => {
            autoHighlighted.current = by === "none" ? value : undefined;
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
        {query.trim() !== "" &&
          shown.length === 0 &&
          savedShown.length === 0 &&
          !sandboxFace &&
          !suggestions.includes(ACTION + "auto") && (
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

function AutoIcon() {
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
      <path d="M3 8h10M8 3v10" />
      <circle cx="8" cy="8" r="5.5" />
    </svg>
  );
}

function PhoneIcon() {
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
      <rect x="4.5" y="1.75" width="7" height="12.5" rx="1.75" />
      <path d="M7 12h2" />
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

/// A machine's icon: its kind's shape. Another machine draws in its own color (machineColor), so
/// it reads the same in the chip, this list and the chat's Environment line; this Mac stays quiet
/// (Leo 2026-10-20: another machine is the news).
export function EnvironmentIcon({ kind, name }: { kind: EnvironmentKind; name?: string }) {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind={kind}
      style={name && kind !== "local" ? { color: machineColor(name) } : undefined}
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
