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
  type SavedEnvironment,
  environmentDigit,
  environmentForDigit,
  environmentReady,
  environmentSections,
  environmentUnavailable,
  numberedEnvironments,
  orderEnvironments,
  savedEnvironmentIsFolder,
  savedEnvironmentLabel,
} from "./environments";
import { TeamTag, type ActiveTeamTag } from "./TeamTag";
import { isCloudMachineRow } from "./cloudMachines";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { machineColor } from "./machineColor";
import { useRowPresence } from "./rowPresence";
import type { RunModeRows } from "./sandboxRun";
import {
  SECTION_LABELS,
  environmentStateLabel,
  ENVIRONMENT_SEARCH_MIN,
  groupUnavailableRows,
  type UnavailableGroup,
  useMachineRefresh,
} from "./environmentPickerModel";

/// The Cloud row's value (cloudRun.ts): not a machine id, and not an action of the list.
const CLOUD_RUN = "\u0000cloud-run";

/// A machine's kind, which the search also matches ("ssh", "cloud").
const KIND_LABELS: Record<EnvironmentKind, StringKey> = {
  local: "composer.envLocal",
  ssh: "composer.envSSH",
  cloud: "composer.cloud",
};
/// The control's look: its icon and short name, its icon alone, or a bordered chip (gallery variants).
export type EnvironmentFaceStyle = "label" | "icon" | "chip";

/// Which rows the list holds (ComposerContext `stripLayout`). `combined`: This Mac and Cloud, a
/// machine only once it is the pick, every machine behind Machines… (one control for both).
/// `where`: where the chat runs, three one-line rows, This Mac, Cloud and Remote, whose
/// pick is the machine control's (`onAnother`). `machines`: which machine, the person's machines
/// with no Cloud row, ready ones first, SSH and Cloud peers alike (their icon is the only mark of
/// how each connects), then Add Machine…; This Mac heads it with `includeLocal`. `run`: ChatGPT's
/// cloud toggle, "Where should this chat run?" over This Mac and Cloud. Cloud picked has no list of
/// its own: Send reuses the person's machine or makes one (Leo, 2026-11-04).
export type EnvironmentRows = "combined" | "where" | "machines" | "run";
/// The cloud toggle's rows' second lines (a gallery arm copying ChatGPT Work; the shipped picker
/// has none, design/environment-picker.md rule 0).
export type RunRowDetails = { local: string; cloud: string };

/// The New Tab page's saved environments in the picker: in Machines… after This Mac, Create
/// environment on the right-click menu, and Edit environment there while one is picked. One that is
/// only a folder on this computer (`savedEnvironmentIsFolder`) is the composer's folder menu's, not
/// a row here; picked, This Mac stays checked.
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
  cloudTeam,
  saved,
  onOpen,
  offload,
  onOffload,
  offloadReason,
  moveTargets,
  onMoveTo,
  runMode,
  closeOnTrustAsk = false,
  faceStyle = "label",
  rows: listRows = "combined",
  includeLocal = true,
  digits = true,
  setupMenu = true,
  onAnother,
  openRequest,
  ownOnly = false,
  runDetails,
  unavailableGroup = "collapsed",
  unavailableExpanded = false,
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
  /// The app's Cloud account state. Only an explicit signed-out answer turns the Cloud row into
  /// Sign in for Cloud; before any answer the row is Cloud. The right-click menu keeps Sign in for
  /// Cloud until the app says signed in.
  cloudSignedIn?: boolean;
  /// The team Cloud runs in (the app's active team): its row names it, so a pick never makes a
  /// machine in a team the person did not see (Leo, 2026-11-09: "i guess is team? it's kinda hard
  /// to realize tho").
  cloudTeam?: ActiveTeamTag;
  saved?: SavedEnvironmentRows;
  /// The list opened, and every few seconds while it stays open: the host reads the machines
  /// again, so each one's status is current.
  onOpen?(): void;
  /// A started chat's move, run by `onOffload`.
  offload?: OffloadKind;
  onOffload?(kind: OffloadKind): void;
  /// Why the move would refuse now (a chat with no first message yet): its row is greyed, says why
  /// under its name, and a pick runs nothing.
  offloadReason?: string;
  /// A started chat's Move to… (Leo, 2026-11-10: "the whole \"move to cloud\" deserves a proper
  /// \"move to other cloud\" ... and \"move to local\""): every place it can go, this Mac and each
  /// Cloud machine but its own. With two or more, or one that `offload` does not cover, the move row
  /// is Move to…, which opens them as a list of their own; a pick runs `onMoveTo` with its id.
  moveTargets?: readonly MoveTarget[];
  onMoveTo?(id: string): void;
  /// A new chat's Run as (hq#3367): Persistent (a chat, as before) or Sandboxed (the
  /// first message runs once on a throwaway Cloud VM).
  runMode?: RunModeRows;
  /// A trust question is the blocking surface; close an already-open destination menu so its
  /// actions remain visible and clickable when the question arrives.
  closeOnTrustAsk?: boolean;
  /// How the control draws (EnvironmentFaceStyle): its icon and short name (the default), its icon
  /// alone, or a bordered chip. The gallery compares them.
  faceStyle?: EnvironmentFaceStyle;
  /// Which rows the list holds (EnvironmentRows); `combined` by default.
  rows?: EnvironmentRows;
  /// `machines`: This Mac heads the list (the machine control that always shows).
  includeLocal?: boolean;
  /// Whether this control owns ⌥⌘1–9 (one control per strip does; the digits always count the
  /// full list, so a digit names the same machine whichever control shows it).
  digits?: boolean;
  /// Whether the right-click setup menu is this control's (one control per strip has it).
  setupMenu?: boolean;
  /// `where`: Remote was picked; the strip shows and opens its machine control.
  onAnother?(): void;
  /// Each new value opens the list (the strip opens the machine control after Remote).
  openRequest?: number;
  /// `machines`: only the person's own machines (SSH), not Cloud machines (Cloud is one pick; its machines are behind Machines…).
  ownOnly?: boolean;
  /// `run`: a second line under This Mac and Cloud (gallery only).
  runDetails?: RunRowDetails;
  /// How a machine list shows the machines acpmux cannot reach (`collapsed` ships; gallery seam).
  unavailableGroup?: UnavailableGroup;
  /// Gallery seam: the Unavailable group starts open.
  unavailableExpanded?: boolean;
}) {
  // A picked saved environment is the current row: every machine row is then a change. One that is
  // only a folder on this computer leaves This Mac the current row.
  const listedSaved = useMemo(
    () => (saved?.environments ?? []).filter((environment) => !savedEnvironmentIsFolder(environment)),
    [saved?.environments],
  );
  const currentRow =
    saved?.current !== undefined && listedSaved.some((environment) => environment.id === saved.current)
      ? SAVED + saved.current
      : current;
  const [query, setQuery] = useState("");
  // Whether the machine list's Unavailable group is open; it closes with the list.
  const [showUnavailable, setShowUnavailable] = useState(unavailableExpanded);
  // When the list last opened: which machines are unavailable is read then, so no row moves into or
  // out of the group while the list stays open.
  const [openedAt, setOpenedAt] = useState(() => Date.now());
  const [listOpen, setListOpen] = useState(false);
  // Which list is open: This Mac and Cloud, or every machine (Machines… on the right-click menu).
  const [list, setList] = useState<"main" | "machines" | "moves">("main");
  const trigger = useRef<HTMLButtonElement>(null);
  const escaped = useRef(false);
  const { control, anchor, open, setOpen: setPopoverOpen, side, flip } = useLocationPopover();
  // The time is read in the render that opens the list, and its rows group by it in that same render,
  // so a machine that crossed UNAVAILABLE_AFTER_MS while the list was closed is never drawn and then
  // shrunk away (rowPresence.ts animates a row that leaves an open list).
  const openingAt = open && !listOpen ? Date.now() : undefined;
  if (open !== listOpen) {
    setListOpen(open);
    if (openingAt !== undefined) setOpenedAt(openingAt);
  }
  const groupedAt = openingAt ?? openedAt;
  const setOpen = (next: boolean) => {
    if (next && closeOnTrustAsk) return;
    setPopoverOpen(next);
  };
  // Whether the row Base UI highlights is its own pick (on open): with no search typed, that row draws no
  // highlight, so the open menu shows the current machine by its check alone and the highlight
  // means hover or the arrow keys (Austin 2026-11-02: "This highlighting needs some fix").
  const [highlightAuto, setHighlightAuto] = useState(true);
  const reset = () => {
    setQuery("");
    setList("main");
    setHighlightAuto(true);
    setShowUnavailable(unavailableExpanded);
  };
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) reset();
  });
  useLocationOpener(menu, () => setOpen(true));
  // Not the mount's value: a control that mounts with a request (the machine control Another
  // machine just showed) opens.
  const openSeen = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (openRequest === openSeen.current) return;
    openSeen.current = openRequest;
    if (openRequest !== undefined) setOpen(true);
  });
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
  const machineList = list === "machines" || listRows === "machines";
  const searchable = machineList && environments.length + listedSaved.length >= ENVIRONMENT_SEARCH_MIN;
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
  // Each saved environment's name (savedEnvironmentLabel); one that would still read as a machine's
  // own row ("cmux16", no folder) says it is saved.
  const savedLabels = useMemo(() => {
    const machineNames = new Set(environments.map((environment) => environment.label.toLowerCase()));
    return new Map(
      listedSaved.map((environment) => {
        const label = savedEnvironmentLabel(environment);
        return [
          environment.id,
          machineNames.has(label.toLowerCase()) ? `${label} · ${t("composer.envSaved")}` : label,
        ] as const;
      }),
    );
  }, [environments, listedSaved]);
  // The saved environments, first, by name, machine and the Saved section's name.
  const savedShown = useMemo(
    () =>
      listedSaved.filter((environment) =>
        matches(words, `${savedLabels.get(environment.id) ?? environment.name} ${t("composer.envSaved")}`),
      ),
    [listedSaved, savedLabels, words],
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
  type Action = {
    value: string;
    text: string;
    kind: "local" | "cloud";
    run(): void;
    signsIn?: true;
    /// Why the row runs nothing now: greyed, with this under its name.
    reason?: string;
  };
  // Move to…: the targets as rows of their own list. One target the single move row already covers
  // (Bring Back Local's This Mac, Move to Cloud's only machine) stays that row.
  const targets = onMoveTo ? (moveTargets ?? []) : [];
  const covered =
    targets.length === 1 &&
    offload !== undefined &&
    (offload === "bringBack" ? targets[0]?.kind === "local" : targets[0]?.kind === "cloud");
  const opensMoves = targets.length > 0 && !covered;
  const targetActions: Action[] = opensMoves
    ? targets.map((target) => ({
        value: MOVE_TO + target.id,
        text: target.kind === "local" ? t("composer.thisMac") : target.label,
        kind: target.kind,
        run: () => onMoveTo?.(target.id),
        ...(target.reason ? { reason: target.reason } : {}),
      }))
    : [];
  const move: Action | undefined = opensMoves
    ? { value: MOVE_MENU, text: t("composer.moveToMenu"), kind: "cloud", run: () => undefined }
    : offload && onOffload
      ? {
          value: ACTION + offload,
          text: t(offload === "move" ? "composer.moveToCloud" : "composer.bringBackLocal"),
          kind: offload === "move" ? "cloud" : "local",
          run: () => onOffload(offload),
          ...(offloadReason ? { reason: offloadReason } : {}),
        }
      : undefined;
  // Move to…'s list: each target, then nothing else (Escape closes it, as Machines…).
  const moveRows = targetActions.map((action) => action.value);
  // Cloud: where a chat runs off this Mac. A new chat with `runMode` picks it as where the chat runs
  // (cloudRun.ts: the app picks and sizes a machine, CLOUD_RUN); elsewhere a pick opens the host's
  // New Cloud Machine flow, which stays in the right-click menu either way.
  // Cloud and Sign in for Cloud are one row, never two (Leo, 2026-11-07, of the menu showing both
  // and then dropping the sign-in row: "The thing becomes just one state instead of rapidly
  // switching to another"). Only once the app says signed out does the row read Sign in for Cloud,
  // which signs in only, where Cloud's New Cloud Machine flow would sign in and then make a machine
  // (#27973). Signed in, or before any answer (none kept from an earlier page, cloudMachines.ts),
  // it is Cloud (Leo: "that shouldn't be showing by default"); Cloud's own flow signs in first
  // when it has to. Its value stays the same either way, so an answer that lands
  // while the menu is open changes the row's words in place (RowSwap), never the list's rows. A new
  // chat's Cloud (`runMode`) is where the chat runs, a pick that makes nothing: Send signs in first
  // when it has to (cloudRun.ts `signedIn`), so its list has no sign-in row at all; Sign in for
  // Cloud stays on the control's right-click menu.
  const cloud: Action | undefined =
    onConnect && runMode === undefined
      ? cloudSignedIn !== false
        ? { value: ACTION + "cloud", text: t("composer.cloud"), kind: "cloud", run: () => onConnect("cloud") }
        : {
            value: ACTION + "cloud",
            text: t("composer.cloudSignIn"),
            kind: "cloud",
            run: () => onConnect("cloudSignIn"),
            signsIn: true,
          }
      : undefined;
  const cloudRow = runMode !== undefined ? CLOUD_RUN : cloud?.value;
  // Where: Remote, whose pick is the machine control's. Which machine: Add Machine… last.
  const another: Action | undefined =
    listRows === "where" && onAnother
      ? { value: ANOTHER, text: t("composer.anotherMachine"), kind: "local", run: onAnother }
      : undefined;
  const addMachine: Action | undefined =
    listRows === "machines" && onConnect
      ? {
          value: ACTION + "addMachine",
          text: t("composer.addMachine"),
          kind: "local",
          run: () => onConnect("addMachine"),
        }
      : undefined;
  const actions: Action[] = [
    ...(move ? [move] : []),
    ...targetActions,
    ...(cloud ? [cloud] : []),
    ...(another ? [another] : []),
    ...(addMachine ? [addMachine] : []),
  ];
  // The right-click menu; rebuilt each render, as its items are a handful and read the open state.
  const moreActions = (() => {
    const items: { id: string; label: string; onSelect(): void }[] = [];
    if (!setupMenu) return items;
    // Every machine and saved environment, as a list of its own (the main list has none).
    if (environments.some((environment) => !isLocalId(environment.id)) || listedSaved.length > 0)
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
  // and Cloud (Sign in for Cloud while signed out).
  const pickedOther =
    checkedRow !== undefined && !isLocalId(checkedRow) && (positions.has(checkedRow) || checkedRow.startsWith(SAVED))
      ? checkedRow
      : undefined;
  const main = [
    ...ordered.filter(isLocal).map((environment) => environment.id),
    ...(pickedOther ? [pickedOther] : []),
    ...(move ? [move.value] : []),
    ...(cloudRow ? [cloudRow] : []),
  ];
  // The machines acpmux cannot reach for long, behind the lists' Unavailable row (Leo, 2026-11-09:
  // "drop retired and unreachable machines from the list, or group them at the bottom").
  const unavailableRow = (value: string) => {
    const environment = positions.get(value)?.environment;
    return (
      environment !== undefined && !isCloudMachineRow(environment) && environmentUnavailable(environment, groupedAt)
    );
  };
  const grouped = (rows: readonly string[], tail: readonly string[]) =>
    groupUnavailableRows({
      rows,
      actions: tail,
      unavailable: unavailableRow,
      ...(checkedRow !== undefined ? { kept: checkedRow } : {}),
      searching: words.length > 0,
      group: unavailableGroup,
      toggle: UNAVAILABLE,
      expanded: showUnavailable,
    });
  // Machines…: every machine, This Mac first, and New Tab's saved environments, as the search keeps them.
  const machinesGrouped = grouped(
    [
      ...shown.filter(isLocal).map((environment) => environment.id),
      ...savedShown.map((environment) => SAVED + environment.id),
      ...shown.filter((environment) => !isLocal(environment)).map((environment) => environment.id),
    ],
    [],
  );
  // Where: This Mac, Cloud, Remote (checked while the pick is any other machine or a saved
  // environment). The cloud toggle: This Mac and Cloud.
  // A Cloud machine picked is Cloud's; any other machine (or a saved environment) is Remote's.
  const checkedKind = ordered.find((environment) => environment.id === checkedRow)?.kind;
  const cloudChecked = clouded || (listRows === "where" && checkedKind === "cloud");
  // A saved environment on this Mac is This Mac's row in the Where list.
  const savedLocal =
    listRows === "where" &&
    checkedRow?.startsWith(SAVED) === true &&
    saved?.environments.find((environment) => SAVED + environment.id === checkedRow)?.kind === "local";
  const anotherPicked = checkedRow !== undefined && !isLocalId(checkedRow) && !cloudChecked && !savedLocal;
  const where = [
    ...ordered.filter(isLocal).map((environment) => environment.id),
    ...(cloudRow ? [cloudRow] : []),
    ...(another ? [another.value] : []),
  ];
  // Which machine: the machines a chat can start on first, whatever their kind, then the rest
  // greyed; no Cloud row; Add Machine… last. Saved environments stay behind Machines….
  const readyFirst = (items: Environment[]) => [
    ...items.filter(environmentReady),
    ...items.filter((environment) => !environmentReady(environment)),
  ];
  const choicesGrouped = grouped(
    [
      ...(includeLocal ? shown.filter(isLocal).map((environment) => environment.id) : []),
      ...readyFirst(
        shown.filter((environment) => !isLocal(environment) && !(ownOnly && environment.kind === "cloud")),
      ).map((environment) => environment.id),
    ],
    addMachine && words.length === 0 ? [addMachine.value] : [],
  );
  const machineChoices = choicesGrouped.rows;
  const machines = machinesGrouped.rows;
  const unavailableCount = listRows === "machines" && list === "main" ? choicesGrouped.count : machinesGrouped.count;
  const suggestions =
    list === "moves"
      ? moveRows
      : listRows === "machines" && list === "main"
        ? machineChoices
        : machineList
          ? machines
          : listRows === "where" || listRows === "run"
            ? listRows === "run"
              ? [...ordered.filter(isLocal).map((environment) => environment.id), ...(cloudRow ? [cloudRow] : [])]
              : where
            : main;
  // The rows as they settle while the list is open (rowPresence.ts): it opens with its final rows,
  // and a row the data adds or drops while it stays open grows or shrinks in place. Another list
  // (Machines…) or a search replaces the rows at once.
  const presence = useRowPresence(
    suggestions,
    open,
    `${list}\u0001${query}`,
    (value) => actions.find((action) => action.value === value)?.text ?? "",
  );
  // A leaving row draws as it last drew: its machine or action may already be gone.
  const drawn = useRef(new Map<string, React.ReactNode>());
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
    if (!digits) return;
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
  }, [control, digits]);

  // The row Base UI highlighted by itself (reason "none"), not by the arrow keys or the pointer.
  const autoHighlighted = useRef<string | undefined>(undefined);
  const submit = (value: string) => {
    // A row on its way out (rowPresence.ts) keeps its place in the list but is no pick. It is not
    // a disabled suggestion: Combobox moves those to the end, so the row would jump while it goes.
    if (presence.motion(value) === "leave") return;
    // The Unavailable row opens or closes its group in place; the list stays open.
    if (value === UNAVAILABLE) {
      setShowUnavailable((shown) => !shown);
      return;
    }
    const action = actions.find((candidate) => candidate.value === value);
    // A machine still connecting or down is listed, greyed, in its place, but is no pick: the list
    // stays open.
    const machine = positions.get(value)?.environment;
    if (machine && !environmentReady(machine) && !isCloudMachineRow(machine)) return;
    // A move that would refuse is no pick either: its row already says why.
    if (action?.reason) return;
    // Move to… opens its targets in place, as Machines… does; the list stays open.
    if (value === MOVE_MENU) {
      setQuery("");
      setList("moves");
      return;
    }
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
    // A machine, Remote, or Cloud's New Cloud Machine flow: Persistent again.
    if (!action || (value === ACTION + "cloud" && !action.signsIn) || value === ANOTHER) persistent();
    if (action) action.run();
    // The chat's own machine, paused (cloudMachines.ts withCloudSleep), is still a pick: it resumes.
    else if (value === currentRow && !(machine && isCloudMachineRow(machine))) focusPrompt();
    else if (value.startsWith(SAVED)) saved?.onPick(value.slice(SAVED.length));
    else if (machine) onPick(value);
  };
  const row = (value: string): React.ReactNode => {
    const motion = presence.motion(value);
    if (motion === "leave") return drawn.current.get(value) ?? null;
    const node = rowContent(value);
    if (!React.isValidElement<{ "data-row-motion"?: string }>(node)) return node;
    drawn.current.set(value, React.cloneElement(node, { "data-row-motion": "leave" }));
    return motion ? React.cloneElement(node, { "data-row-motion": motion }) : node;
  };
  const rowContent = (value: string) => {
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
      const checked = listRows === "where" ? cloudChecked : clouded;
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind="cloud"
          data-mode="cloud"
          data-current={checked ? "" : undefined}
          title={t("composer.cloudRunDetail")}
        >
          <EnvironmentIcon kind="cloud" />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.cloud")}</span>
            {listRows === "run" && runDetails && <span className="acpmux-menu-description">{runDetails.cloud}</span>}
          </span>
          {cloudTeam && <TeamTag team={cloudTeam} />}
          <span className="acpmux-location-check" aria-hidden="true">
            {checked && <CheckIcon />}
          </span>
        </span>
      );
    }
    if (value === UNAVAILABLE) {
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new acpmux-env-unavailable"
          data-action="unavailable"
          data-expanded={showUnavailable ? "" : undefined}
          aria-expanded={showUnavailable}
        >
          <UnavailableChevron />
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{t("composer.envUnavailableGroup", { n: unavailableCount })}</span>
          </span>
          <span className="acpmux-location-check" aria-hidden="true" />
        </span>
      );
    }
    const action = actions.find((candidate) => candidate.value === value);
    if (action) {
      const checked =
        (action === another && anotherPicked) || (action === cloud && listRows === "where" && cloudChecked);
      return (
        <span
          className="acpmux-location-row acpmux-env-row acpmux-env-new"
          data-kind={action.kind}
          data-action={
            action === another
              ? "another"
              : action === addMachine
                ? "addMachine"
                : value === MOVE_MENU
                  ? "moveTo"
                  : value.startsWith(MOVE_TO)
                    ? "moveTarget"
                    : undefined
          }
          data-current={checked ? "" : undefined}
          data-ready={action.reason ? "false" : undefined}
          aria-disabled={action.reason ? true : undefined}
          title={action.reason}
        >
          {action === another ? (
            <AnotherMachineIcon />
          ) : value === MOVE_MENU ? (
            <MoveIcon />
          ) : value.startsWith(MOVE_TO) ? (
            <EnvironmentIcon kind={action.kind} {...(action.kind === "cloud" ? { name: action.text } : {})} />
          ) : action === addMachine ? (
            <PlusIcon />
          ) : (
            <EnvironmentIcon kind={action.kind} />
          )}
          <span className="acpmux-menu-text acpmux-location-name">
            <span className="acpmux-menu-label">{action.text}</span>
            {action.reason && <span className="acpmux-menu-description">{action.reason}</span>}
          </span>
          {action === cloud && !action.signsIn && cloudTeam && <TeamTag team={cloudTeam} />}
          {value === MOVE_MENU ? (
            <span className="acpmux-location-check acpmux-env-more-chevron" aria-hidden="true">
              <ChevronIcon />
            </span>
          ) : (
            <span className="acpmux-location-check" aria-hidden="true">
              {checked && <CheckIcon />}
            </span>
          )}
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
            <span className="acpmux-menu-label">{savedLabels.get(environment.id) ?? environment.name}</span>
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
        data-current={environment.id === checkedRow || (savedLocal && isLocal(environment)) ? "" : undefined}
        data-ready={greyed ? "false" : undefined}
        aria-disabled={greyed ? true : undefined}
        // This Mac's row says "This Mac"; its own name is the row's tooltip.
        title={isLocal(environment) && environment.label !== t("composer.thisMac") ? environment.label : undefined}
      >
        <EnvironmentIcon kind={environment.kind} name={environment.label} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{isLocal(environment) ? t("composer.thisMac") : environment.label}</span>
          {listRows === "run" && runDetails && isLocal(environment) && (
            <span className="acpmux-menu-description">{runDetails.local}</span>
          )}
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
        {number !== undefined && digits && <kbd className="acpmux-env-key">⌥⌘{number}</kbd>}
        <span className="acpmux-location-check" aria-hidden="true">
          {(environment.id === checkedRow || (savedLocal && isLocal(environment))) && <CheckIcon />}
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
      data-rows={listRows}
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
          (machineList ? " acpmux-env-machines" : "") +
          ` acpmux-env-rows-${listRows}` +
          (list === "moves" ? " acpmux-env-moves" : "") +
          (highlightAuto && query.trim() === "" ? " acpmux-env-highlight-auto" : "")
        }
        side={side}
        flip={flip}
        finalFocus={false}
      >
        {listRows === "run" && <div className="acpmux-env-heading">{t("composer.whereRun")}</div>}
        {list === "moves" && <div className="acpmux-env-heading">{t("composer.moveToMenu")}</div>}
        <Combobox
          suggestions={presence.rows}
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
            setHighlightAuto(by === "none");
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
/// Where's Remote row.
const ANOTHER = ACTION + "another";
/// A started chat's Move to… row, which opens its targets.
const MOVE_MENU = ACTION + "moveTo";
/// One Move to… target's row: its id after this.
const MOVE_TO = ACTION + "moveTo:";

/// One place a started chat can move (Move to…): `local` is this Mac, whose row says This Mac.
export interface MoveTarget {
  readonly id: string;
  readonly label: string;
  readonly kind: "local" | "cloud";
  /// Why a move there would refuse now: the row is greyed with it.
  readonly reason?: string;
}

/// A machine list's Unavailable row, which opens the machines acpmux cannot reach.
const UNAVAILABLE = ACTION + "unavailable";

/// The Unavailable row's mark: a chevron that turns down while its group is open (CSS).
function UnavailableChevron() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon acpmux-env-unavailable-chevron ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M6 4l4 4-4 4" />
    </svg>
  );
}
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

/// Remote (one of the person's own machines): a globe, any kind of machine alike.
export function AnotherMachineIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind="another"
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
      <circle cx="8" cy="8" r="5.75" />
      <path d="M2.25 8h11.5M8 2.25c1.6 1.6 2.4 3.5 2.4 5.75S9.6 12.15 8 13.75M8 2.25C6.4 3.85 5.6 5.75 5.6 8s.8 4.15 2.4 5.75" />
    </svg>
  );
}

/// Which machine (the machine chip): a server, as Codex desktop's machine chip.
export function ServerIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind="server"
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
      <rect x="3" y="2.5" width="10" height="7" rx="1.2" />
      <path d="M5.5 6h5M2.5 12h1M5.5 12h1M8.5 12h1M11.5 12h1" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind="add"
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

/// Move to…: an arrow leaving a box.
function MoveIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon acpmux-env-icon ui-ghost-icon"
      data-kind="move"
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
      <path d="M9.5 3H4a1.5 1.5 0 0 0-1.5 1.5v7A1.5 1.5 0 0 0 4 13h5.5M7 8h6.5M11 5.5 13.5 8 11 10.5" />
    </svg>
  );
}

/// A row that opens a list of its own: a chevron where a check goes.
function ChevronIcon() {
  return (
    <svg
      className="acpmux-icon"
      width={12}
      height={12}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="m6 3.5 4.5 4.5L6 12.5" />
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
