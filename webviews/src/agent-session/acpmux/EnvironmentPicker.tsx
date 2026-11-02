import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { ContextMenu } from "../../ui/ContextMenu";
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

/// The Cloud row's value (cloudRun.ts): not a machine id, and not an action of the list.
const CLOUD_RUN = "\u0000cloud-run";

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
  // A machine that failed to start says so, never "Not connected", which reads as a link to fix.
  failed: "switch.failedShort",
};
function cloudMachineLabel(machine: CloudMachine): string {
  return t(CLOUD_STAGE_LABELS[machine.stage] ?? "composer.envNotConnected");
}

/// The machines (and saved environments) a list holds before it gets a search field.
export const ENVIRONMENT_SEARCH_MIN = 8;

/// The control's look: its icon and short name, its icon alone, or a bordered chip (gallery variants).
export type EnvironmentFaceStyle = "label" | "icon" | "chip";

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

/// The environment picker (not behind Labs since Leo's 2026-10-30 order): where a chat runs, as Codex's "Where
/// should this chat run?" menu has it (Leo, 2026-10-31). Two rows, This Mac and Cloud, one line
/// each, and no machine list (Leo, 2026-10-31: "it's just a cloud button"). Cloud gives a new
/// workspace its own new machine (cmux-tui cloud.startChat, one workspace per machine, #30020), so
/// the picker never chooses one. A machine picked elsewhere is the only other row, checked, while it
/// is the pick. Every machine acpmux lists, and New Tab's saved environments, are behind Machines…
/// on the control's right-click menu (`list` "machines"): the ones a chat can start on first and
/// the rest greyed with their state, a search field from ENVIRONMENT_SEARCH_MIN. ⌥⌘1–9 pick the
/// first nine that can take a chat, also while the composer it heads has focus. The setup actions
/// (New Cloud Machine…, Open Cloud…, SSH…, Add Machine…, Connect Phone…, and on the New Tab page
/// Create and Edit environment) are the right-click menu too, besides their homes in the app. A
/// started chat's picker lists only where it runs and its move (`offload`): Move to Cloud from this
/// Mac, Bring Back Local from a Cloud machine. A new chat with `runMode` (hq#3367) also offers
/// Sandboxed as Cloud's other face, with no row of its own: shown while ⌥ is held and while it is
/// the pick.
export function EnvironmentPicker({
  label,
  menu,
  value,
  face,
  environments,
  current,
  onPick,
  onConnect,
  cloudSignedIn,
  saved,
  onOpen,
  offload,
  onOffload,
  runMode,
  closeOnTrustAsk = false,
  faceStyle = "label",
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
  /// The app's Cloud account state; only an explicit signed-in reply hides the sign-in action.
  /// A fresh home can have no Cloud section or no reply from the host yet, and is still signed out
  /// for the purpose of offering the existing sign-in entry point.
  cloudSignedIn?: boolean;
  saved?: SavedEnvironmentRows;
  /// The list opened, and every few seconds while it stays open: the host reads the machines
  /// again, so each one's status is current.
  onOpen?(): void;
  /// A started chat's move, run by `onOffload`.
  offload?: OffloadKind;
  onOffload?(kind: OffloadKind): void;
  /// A new chat's Run as (hq#3367): Persistent (a chat, as before) or Sandboxed (the
  /// first message runs once on a throwaway Cloud VM).
  runMode?: RunModeRows;
  /// A trust question is the blocking surface; close an already-open destination menu so its
  /// actions remain visible and clickable when the question arrives.
  closeOnTrustAsk?: boolean;
  /// How the control draws (EnvironmentFaceStyle): its icon and short name (the default), its icon
  /// alone, or a bordered chip. The gallery compares them.
  faceStyle?: EnvironmentFaceStyle;
}) {
  // A picked saved environment is the current row: every machine row is then a change.
  const currentRow = saved?.current !== undefined ? SAVED + saved.current : current;
  const [query, setQuery] = useState("");
  // Which list is open: This Mac and Cloud, or every machine (Machines… on the right-click menu).
  const [list, setList] = useState<"main" | "machines">("main");
  const trigger = useRef<HTMLButtonElement>(null);
  const escaped = useRef(false);
  const { control, anchor, open, setOpen: setPopoverOpen, side, flip } = useLocationPopover();
  const setOpen = (next: boolean) => {
    if (next && closeOnTrustAsk) return;
    setPopoverOpen(next);
  };
  const reset = () => {
    setQuery("");
    setList("main");
  };
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) reset();
  });
  useLocationOpener(menu, () => setOpen(true));
  useEffect(() => {
    if (!closeOnTrustAsk || !open) return;
    setPopoverOpen(false);
    setQuery("");
    setList("main");
  }, [closeOnTrustAsk, open, setPopoverOpen]);
  // Sandboxed or Cloud is the pick: no machine row is checked, and a machine pick goes back to Persistent.
  const sandboxed = runMode?.mode === "sandboxed";
  const clouded = runMode?.mode === "cloud";
  const checkedRow = sandboxed || clouded ? undefined : currentRow;
  const persistent = () => {
    if (runMode && runMode.mode !== "persistent") runMode.onMode("persistent");
  };
  // ⌥ held while the list is open shows Cloud's other face (as a Mac menu's alternate).
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
  const isLocalId = (id: string) => sections.get(id) === "local";
  const isLocal = (environment: Environment) => isLocalId(environment.id);
  const numbers = useMemo(
    () => new Map(numberedEnvironments(environments).map((environment, index) => [environment.id, index + 1])),
    [environments],
  );
  // Only the machine list searches, and only where it is long (Leo, 2026-10-31): a few machines are
  // read at a glance, and the main list is two rows.
  const machineList = list === "machines";
  const searchable = machineList && environments.length + (saved?.environments.length ?? 0) >= ENVIRONMENT_SEARCH_MIN;
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
  // Each shown row's environment and place in the list.
  const positions = useMemo(
    () => new Map(shown.map((environment, index) => [environment.id, { environment, index }])),
    [shown],
  );
  // The list is two rows, as Codex's "Where should this chat run?" (Leo, 2026-10-31: "JUST A LITTLE
  // CLOUD ICON OR FUCKING THE SELECTION", then "we ideally also can just hide the machines too and
  // it's just a cloud button"): This Mac and Cloud. No machine list, no section headers and no
  // second lines. The other machines are Machines… on the control's right-click menu
  // (`moreActions`), with the setup actions (New Cloud Machine…, Open Cloud…, SSH…, Add Machine…,
  // Connect Phone…, Create and Edit environment), which also stay in the command palette, the File
  // menu, Settings > Devices and the Cloud page. A started chat's list is where it runs and its one
  // move.
  const editing = saved?.current;
  type Action = { value: string; text: string; kind: "local" | "cloud"; run(): void };
  const move: Action | undefined =
    offload && onOffload
      ? {
          value: ACTION + offload,
          text: t(offload === "move" ? "composer.moveToCloud" : "composer.bringBackLocal"),
          kind: offload === "move" ? "cloud" : "local",
          run: () => onOffload(offload),
        }
      : undefined;
  // Cloud: where a chat runs off this Mac. A new chat with `runMode` picks it as where the chat runs
  // (cloudRun.ts: the app picks and sizes a machine, CLOUD_RUN); elsewhere a pick opens the host's
  // New Cloud Machine flow, which stays in the right-click menu either way.
  const cloud: Action | undefined =
    onConnect && runMode === undefined
      ? { value: ACTION + "cloud", text: t("composer.cloud"), kind: "cloud", run: () => onConnect("cloud") }
      : undefined;
  const cloudRow = runMode !== undefined ? CLOUD_RUN : cloud?.value;
  // Signed out (or before the app's Cloud reply), Sign in for Cloud follows Cloud: it signs in only,
  // where Cloud's New Cloud Machine flow would sign in and then make a machine (#27973).
  const signIn: Action | undefined =
    onConnect && cloudSignedIn !== true
      ? {
          value: ACTION + "cloudSignIn",
          text: t("composer.cloudSignIn"),
          kind: "cloud",
          run: () => onConnect("cloudSignIn"),
        }
      : undefined;
  const actions: Action[] = [...(move ? [move] : []), ...(cloud ? [cloud] : []), ...(signIn ? [signIn] : [])];
  // The right-click menu; rebuilt each render, as its items are a handful and read the open state.
  const moreActions = (() => {
    const items: { id: string; label: string; onSelect(): void }[] = [];
    // Every machine and saved environment, as a list of its own (the main list has none).
    if (environments.some((environment) => !isLocalId(environment.id)) || (saved?.environments.length ?? 0) > 0)
      items.push({
        id: "machines",
        label: t("composer.machinesList"),
        onSelect: () => {
          setQuery("");
          setList("machines");
          setOpen(true);
        },
      });
    if (onConnect) {
      if (cloudSignedIn !== true)
        items.push({ id: "cloudSignIn", label: t("composer.cloudSignIn"), onSelect: () => onConnect("cloudSignIn") });
      for (const [kind, key] of [
        ["cloud", "composer.newCloudMachine"],
        ["cloudPage", "composer.openCloud"],
        ["ssh", "composer.connectSSH"],
        ["addMachine", "composer.addMachine"],
        ["phone", "composer.connectPhone"],
      ] as const) {
        items.push({ id: kind, label: t(key), onSelect: () => onConnect(kind) });
      }
    }
    if (saved) {
      items.push({ id: "create", label: t("environment.create"), onSelect: saved.onCreate });
      if (editing !== undefined)
        items.push({ id: "edit", label: t("environment.edit"), onSelect: () => saved.onEdit(editing) });
    }
    return items;
  })();
  // The main list: This Mac, the picked machine or saved environment when it is neither This Mac nor
  // a new Cloud machine (one checked row, so the pick is never hidden), a started chat's move,
  // Cloud, and Sign in for Cloud while signed out.
  const pickedOther =
    checkedRow !== undefined && !isLocalId(checkedRow) && (positions.has(checkedRow) || checkedRow.startsWith(SAVED))
      ? checkedRow
      : undefined;
  const main = [
    ...ordered.filter(isLocal).map((environment) => environment.id),
    ...(pickedOther ? [pickedOther] : []),
    ...(move ? [move.value] : []),
    ...(cloudRow ? [cloudRow] : []),
    ...(signIn ? [signIn.value] : []),
  ];
  // Machines…: every machine, This Mac first, and New Tab's saved environments, as the search keeps them.
  const machines = [
    ...shown.filter(isLocal).map((environment) => environment.id),
    ...savedShown.map((environment) => SAVED + environment.id),
    ...shown.filter((environment) => !isLocal(environment)).map((environment) => environment.id),
  ];
  const suggestions = machineList ? machines : main;
  // Cloud's row shows Sandboxed instead while ⌥ is held (or, once picked, until it is).
  const sandboxFace = offersSandbox && sandboxed !== alternate;

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
    if (value === CLOUD_RUN) {
      // The picked mode changes no folder or machine, so no caller moves focus: the prompt takes it.
      if (sandboxFace) {
        if (sandboxed) focusPrompt();
        else runMode?.onMode("sandboxed");
        return;
      }
      if (!clouded) runMode?.onMode("cloud");
      focusPrompt();
      return;
    }
    // A machine, or Cloud's New Cloud Machine flow: Persistent again.
    if (!action || value === ACTION + "cloud") persistent();
    if (action) action.run();
    else if (value === currentRow) focusPrompt();
    else if (value.startsWith(SAVED)) saved?.onPick(value.slice(SAVED.length));
    else if (machine) onPick(value);
  };
  const row = (value: string) => {
    if (value === CLOUD_RUN && sandboxFace) {
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind="cloud"
          data-mode="sandboxed"
          data-current={sandboxed ? "" : undefined}
        >
          <EnvironmentIcon kind="cloud" />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.sandboxed")}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {sandboxed && <CheckIcon />}
          </span>
        </span>
      );
    }
    // Cloud as where the new chat runs: one line, as This Mac; what it does is its tooltip.
    if (value === CLOUD_RUN) {
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind="cloud"
          data-mode="cloud"
          data-current={clouded ? "" : undefined}
          title={t("composer.cloudRunDetail")}
        >
          <EnvironmentIcon kind="cloud" />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.cloud")}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true">
            {clouded && <CheckIcon />}
          </span>
        </span>
      );
    }
    const action = actions.find((candidate) => candidate.value === value);
    if (action) {
      return (
        <span className="acpmux-location-row acpmux-env-row acpmux-env-new" data-kind={action.kind}>
          <EnvironmentIcon kind={action.kind} />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{action.text}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true" />
        </span>
      );
    }
    if (value.startsWith(SAVED)) {
      const environment = savedShown.find((candidate) => SAVED + candidate.id === value);
      if (!environment) return null;
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-saved"
          data-kind={environment.kind}
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
    const { environment } = position;
    const number = numbers.get(environment.id);
    const ready = environmentReady(environment);
    // An account Cloud machine acpmux does not list is a pick (it resumes or opens), not greyed.
    const greyed = !ready && !isCloudMachineRow(environment);
    return (
      <span
        className="acpmux-location-row acpmux-env-row"
        data-kind={environment.kind}
        data-current={environment.id === checkedRow ? "" : undefined}
        data-ready={greyed ? "false" : undefined}
        aria-disabled={greyed ? true : undefined}
        // This Mac's row says "This Mac"; its own name is the row's tooltip.
        title={isLocal(environment) && environment.label !== t("composer.thisMac") ? environment.label : undefined}
      >
        <EnvironmentIcon kind={environment.kind} name={environment.label} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{isLocal(environment) ? t("composer.thisMac") : environment.label}</span>
        </span>
        {/* A machine a chat cannot start on yet says why, greyed; one that can shows a status dot.
            Only an SSH or Cloud machine acpmux lists has a status; this Mac never shows one. */}
        {!ready && <span className="acpmux-env-state">{environmentStateLabel(environment)}</span>}
        {ready && environment.loadWarning && (
          <span className="acpmux-env-state" data-warning="true">
            {environment.loadWarning}
          </span>
        )}
        {ready && !environment.loadWarning && environment.kind !== "local" && environment.connected !== undefined && (
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

  const button = (
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
  );
  return (
    // tooltip-allow: at or under a 460 px pane the environment shows only its icon; the tooltip names it
    <span
      ref={control}
      className="acpmux-location-picker"
      data-kind="computer"
      data-face={faceStyle}
      title={label + ": " + value}
    >
      {moreActions.length > 0 ? (
        <ContextMenu items={moreActions} className="acpmux-env-more" targets="own">
          {button}
        </ContextMenu>
      ) : (
        button
      )}
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) reset();
        }}
        anchor={open ? anchor : null}
        label={label}
        className={
          "acpmux-menu acpmux-location-menu acpmux-folder-popover acpmux-env-popover" +
          (searchable ? "" : " acpmux-env-searchless") +
          (machineList ? " acpmux-env-machines" : "")
        }
        side={side}
        flip={flip}
        finalFocus={false}
      >
        <Combobox
          suggestions={suggestions}
          // A short list has no search: the field only carries the arrows, Return and Escape.
          onQuery={searchable ? setQuery : () => undefined}
          onSubmit={submit}
          onCancel={close}
          onCommand={(event) => {
            if (event.key === "Escape") escaped.current = true;
            if (event.key === "Tab") event.preventDefault();
            // Return runs an action (Cloud opens New Cloud Machine; Move to Cloud moves the chat)
            // only once the arrow keys or the pointer reached it, never when Base UI highlighted it on
            // its own: a search that leaves no machine moves that highlight onto an action.
            if (event.key === "Enter" && autoHighlighted.current?.startsWith(ACTION)) {
              event.preventDefault();
              event.preventBaseUIHandler?.();
            }
          }}
          onHighlight={(highlighted, by) => {
            autoHighlighted.current = by === "none" ? highlighted : undefined;
          }}
          label={searchable ? t("composer.environmentSearch") : label}
          {...(searchable ? { placeholder: t("composer.environmentSearch") } : {})}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          renderItem={row}
          autoHighlight
          inline
        />
        {machineList && query.trim() !== "" && shown.length === 0 && savedShown.length === 0 && (
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
