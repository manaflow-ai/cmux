import React, { useEffect, useMemo, useRef, useState } from "react";
import { useNativePopup } from "../../ui/nativePopup";
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
  /// A new chat's Run as (preview, hq#3367): Persistent (a chat, as before) or Sandboxed (the
  /// first message runs once on a throwaway Cloud VM).
  runMode?: RunModeRows;
}) {
  // A picked saved environment is the current row: every machine row is then a change.
  const currentRow = saved?.current !== undefined ? SAVED + saved.current : current;
  const [query, setQuery] = useState("");
  const trigger = useRef<HTMLButtonElement>(null);
  const { control, open, setOpen, side } = useLocationPopover();
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
    kind: "local" | "ssh" | "cloud" | "saved" | "phone";
    run(): void;
  };
  const actions: Action[] = [
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
            run: () => saved.onEdit(editing),
          },
        ]
      : []),
    ...(onConnect
      ? [
          { value: ACTION + "ssh", text: t("composer.connectSSH"), kind: "ssh" as const, run: () => onConnect("ssh") },
          // Connect Phone… opens the Mobile Pairing page: cmux on iPhone reaches this Mac.
          {
            value: ACTION + "phone",
            text: t("composer.connectPhone"),
            kind: "phone" as const,
            run: () => onConnect("phone"),
          },
          // The list's last row: Add Device, where a machine on the tailnet or in ~/.ssh/config is
          // one Add away (its agent daemon installed and kept current), or a new Cloud VM.
          {
            value: ACTION + "addMachine",
            text: t("composer.addMachine"),
            kind: "ssh" as const,
            run: () => onConnect("addMachine"),
          },
        ]
      : []),
  ];
  const cloudShown = shown.some((environment) => sectionOf(environment) === "fleet");
  const localShown = shown.some((environment) => sectionOf(environment) === "local");
  const firstNew = actions.find((action) => action.kind !== "cloud" && action.kind !== "local");
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
  const nativeRows = useMemo(() => {
    const rows: Array<{
      id: string;
      kind: "action" | "section" | "text";
      label: string;
      description?: string;
      icon?: string;
      checked?: boolean;
      disabled?: boolean;
      disabledReason?: string;
      shortcut?: string;
    }> = [];
    if (savedShown.length > 0) {
      rows.push({ id: "section:saved", kind: "section", label: t("composer.envSaved") });
      savedShown.forEach((environment) =>
        rows.push({
          id: SAVED + environment.id,
          kind: "action",
          label: environment.name,
          checked: SAVED + environment.id === checkedRow,
          icon: environment.kind === "cloud" ? "cloud" : environment.kind === "ssh" ? "network" : "computer",
        }),
      );
    }
    shown.forEach((environment, index) => {
      const section = sectionOf(environment);
      const previous = index > 0 ? sectionOf(shown[index - 1]!) : undefined;
      if (section !== previous) rows.push({ id: `section:${section}`, kind: "section", label: t(SECTION_LABELS[section]) });
      const ready = environmentReady(environment);
      const greyed = !ready && !isCloudMachineRow(environment);
      rows.push({
        id: environment.id,
        kind: "action",
        label: environment.label,
        description: !ready
          ? environmentStateLabel(environment)
          : environment.kind !== "local" && environment.connected !== undefined
            ? t(environment.connected ? "composer.envConnected" : "composer.envNotConnected")
            : undefined,
        checked: environment.id === checkedRow,
        disabled: greyed,
        disabledReason: greyed ? environmentStateLabel(environment) : undefined,
        icon: environment.kind === "cloud" ? "cloud" : environment.kind === "ssh" ? "network" : "computer",
        shortcut: numbers.get(environment.id) !== undefined ? `⌥⌘${numbers.get(environment.id)}` : undefined,
      });
    });
    actions.forEach((action, index) => {
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
      if (section) rows.push({ id: `section:action:${index}`, kind: "section", label: section });
      const sandbox = action.value === ACTION + "cloud" && sandboxFace;
      rows.push({
        id: action.value,
        kind: "action",
        label: sandbox ? t("composer.sandboxed") : action.text,
        description: sandbox ? t("composer.sandboxedDetail") : action.detail,
        checked: sandbox ? sandboxed : undefined,
        icon: action.kind === "cloud" ? "cloud" : action.kind === "ssh" ? "network" : action.kind === "phone" ? "phone" : "plus",
      });
    });
    return rows;
  }, [actions, checkedRow, cloudShown, firstNew, localShown, numbers, sandboxFace, sandboxed, savedShown, sectionOf, shown]);

  useNativePopup({
    open,
    anchor: () => control.current,
    model: {
      side,
      align: "start",
      width: 380,
      title: label,
      search: { id: "query", value: query, placeholder: t("composer.environmentSearch") },
      rows: nativeRows,
    },
    onEvent: (event) => {
      if (event.type === "search" && event.id === "query") setQuery(event.value ?? "");
      else if (event.type === "pick" && event.id) submit(event.id);
    },
    onDismiss: close,
  });

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
