import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { Popover } from "../../ui/Popover";
import { BrowseFailure, browseFailureMessage } from "./BrowseFailure";
import type { AcpmuxSnapshot } from "./model";
import { ChevronIcon } from "./ComposerPickers";
import { Spinner } from "./conversation/icons";
import {
  AnotherMachineIcon,
  EnvironmentIcon,
  EnvironmentPicker,
  ServerIcon,
  type RunRowDetails,
  type EnvironmentFaceStyle,
  SECTION_LABELS,
  environmentStateLabel,
  useMachineRefresh,
  type SavedEnvironmentRows,
} from "./EnvironmentPicker";
import { machineColor } from "./machineColor";
import {
  isCloudMachineRow,
  refreshCloudMachines,
  runCloudMachine,
  useCloudMachines,
  useCloudSignedIn,
  withCloudMachines,
  withCloudSleep,
  type CloudMachine,
} from "./cloudMachines";
import {
  environmentReady,
  environmentSections,
  knownMachines,
  orderEnvironments,
  savedEnvironmentIsFolder,
  savedEnvironmentLabel,
  type ConnectKind,
  type EnvironmentKind,
  type OffloadKind,
} from "./environments";
import { FolderPopover } from "./FolderPopover";
import { ExtraFolderList } from "./ExtraFolderList";
import {
  addExtraFolder,
  draftFolders,
  removeExtraFolder,
  type ExtraFolderControl,
  type ExtraFolderRows,
} from "./extraFolders";
import type { BrowseRequest, BrowseResult } from "./AddProjectPanel";
import type { Project } from "./ProjectChooser";
import { ProjectBadge } from "./ProjectBadge";
import { projectSuffixes } from "./projectSuffix";
import { belowCheckout, folderRepo, isMainCheckout, worktreeName, type ProjectRepo } from "./projectRepos";
import { isAgentHome, projectLabel } from "./sessionList";
import { translate as t, useT } from "./i18n";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { focusAfterEscape } from "../../ui/escapeFocus";
import type { RunModeRows } from "./sandboxRun";
import { machineLoadWarning, type MachineResources } from "./machineResources";
import { useComposerSettings } from "./composerSettings";
import { repickMachine, type RepickMachine } from "./cloudRepick";

export const CONTEXT_LABELS = {
  computer: "composer.computer",
  folder: "composer.folder",
  local: "composer.thisMac",
  chooseComputer: "composer.chooseComputer",
  chooseFolder: "composer.chooseFolder",
  chooseFolderMenu: "composer.chooseFolderMenu",
  folderSearch: "composer.folderSearch",
  cloud: "composer.cloud",
  connectSSH: "composer.connectSSH",
  addComputer: "composer.addComputer",
  newCloudMachine: "composer.newCloudMachine",
  newChatHere: "composer.newChatHere",
  machine: "composer.machine",
  chooseMachine: "composer.chooseMachine",
  noProject: "composer.noProject",
  environment: "composer.environment",
} as const;

/// How a new chat's strip asks where it runs (gallery seam; `where-machine` ships). Leo, 2026-11-03,
/// on Codex desktop's strip: "chatgpt codex has nicer ways to deal with stuff".
/// - `where-machine` (Codex desktop): Project | Where (This Mac, Cloud, Another machine) | Machine,
///   the machine control only while the pick is another machine. Cloud has none: it gives the
///   workspace its own new machine (design/composer.md rule 18).
/// - `where-machine-always`: the same, the machine control also shown on This Mac (its own name
///   with its live dot); never for Cloud.
/// - `cloud-toggle` (ChatGPT Work): Project | Machine (This Mac first), and a cloud toggle at the
///   strip's end asking "Where should this chat run?" (This Mac, Cloud).
/// - `combined`: one control for both, This Mac and Cloud, the machines behind Machines….
/// A started chat always has the one combined control (its machine and its one move).
export type StripLayout = "where-machine" | "where-machine-always" | "cloud-toggle" | "combined";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
type Session = AcpmuxSnapshot["sessions"][number];
/// `section`: a machine list's section name; `disabled`: listed, but not a pick (still connecting or down).
type Location = {
  id: string;
  label: string;
  detail?: string;
  repo?: ProjectRepo;
  section?: string;
  disabled?: boolean;
  warning?: boolean;
};
type Computer = Location & {
  kind: EnvironmentKind;
  connected?: boolean;
  state?: string;
  cloudMachine?: CloudMachine;
  resources?: MachineResources;
};
const NO_PEER_KINDS: Record<string, "ssh" | "cloud"> = {};
const NO_PEER_CONNECTED: Record<string, boolean> = {};
const NO_PEER_STATES: Record<string, string> = {};
const NO_PEER_RESOURCES: Record<string, MachineResources> = {};
const NO_OFFLOADS: readonly OffloadKind[] = [];

/// The location strip on the composer card's top edge (hq#1957 composer location strip): folder ·
/// computer, and the branch at the end. New chats can choose a local or Cloud computer and one of
/// its known folders. Once the first turn starts both are fixed (Leo 2026-10-13): the folder's
/// menu starts a new chat (`onNewChat`) there or in another folder. The strip always draws, at one
/// height, so a project chosen later or a host name that arrives late moves nothing.
export function ComposerContext({
  summary,
  sessions = [],
  peers = [],
  peerKinds = NO_PEER_KINDS,
  peerConnected = NO_PEER_CONNECTED,
  peerStates = NO_PEER_STATES,
  peerResources = NO_PEER_RESOURCES,
  environments = false,
  started = false,
  onProject,
  projectChoices,
  machineFolders,
  onBrowseProject,
  onNewWorktree,
  onNoProject,
  noProject = false,
  localName,
  onNewChat,
  onBrowseFolder,
  onConnect,
  connectOnlyWhenEmpty = false,
  onOffload,
  offloads = NO_OFFLOADS,
  saved,
  onRefreshMachines: onRefreshPeers,
  folderNote,
  onComputer,
  onRepick,
  cloudMachines,
  onCloudMachine = (machine) => void runCloudMachine(machine),
  onCloudMachinePicked,
  runMode,
  closeOnTrustAsk = false,
  showMachineLoadWarnings,
  environmentFace,
  stripLayout = "where-machine",
  runDetails,
  cloudWorksOn,
  cloudSignedIn: cloudSignedInSeam,
  extraFolders,
}: {
  summary?: Summary;
  sessions?: Session[];
  peers?: string[];
  /// Each peer's transport (`AcpmuxSnapshot.peerKinds`): its section in the environment picker.
  peerKinds?: Record<string, "ssh" | "cloud">;
  /// Whether each peer is connected (`AcpmuxSnapshot.peerConnected`): the picker's status mark.
  peerConnected?: Record<string, boolean>;
  /// Each peer's link state (`AcpmuxSnapshot.peerStates`): a machine still connecting or down is
  /// listed greyed with it, and is not a pick.
  peerStates?: Record<string, string>;
  /// Each peer's cached one-minute host health from the same acpmux reading as the sidebar.
  peerResources?: Record<string, MachineResources>;
  /// The computer control is the environment picker (EnvironmentPicker.tsx), with Local, SSH and
  /// Cloud sections and ⌥⌘1–9. The agent page always passes it (not behind Labs, Leo 2026-10-30);
  /// off, the plain Computer menu, for surfaces that pass nothing.
  environments?: boolean;
  started?: boolean;
  onProject?(cwd: string, peer?: string): void;
  projectChoices?: Project[];
  /// A chat on another machine: that machine's own folders (its `project.list`), listed in its
  /// folder menu while the chat's own machine is picked; a pick there is this chat's folder.
  machineFolders?: Project[];
  onBrowseProject?(request?: BrowseRequest): Promise<BrowseResult> | BrowseResult | void;
  /// New Worktree (cx-lyqio.2): a new chat on this Mac starts in a worktree of its folder.
  onNewWorktree?(cwd: string): void;
  /// A new chat's Do not work in a project (FolderPopover); `noProject` while it is the choice.
  onNoProject?(): void;
  noProject?: boolean;
  /// This Mac's name (the handshake's `machineName`).
  localName?: string;
  /// A started chat's New Chat Here, or a folder picked from its menu: a new chat in that folder,
  /// in a tab of its own.
  onNewChat?(cwd: string): void;
  /// A started chat's Choose folder…: the host's folder panel, then a new chat there.
  onBrowseFolder?(): Promise<string | undefined>;
  /// A new chat's Computer menu ends with SSH… and New Cloud Machine, which open the host's
  /// connect flows (Lawrence 2026-10-06: "I cannot click on cmux Cloud SSH").
  onConnect?(kind: ConnectKind): void;
  /// New Tab without Labs exposes setup only until another computer is listed.
  connectOnlyWhenEmpty?: boolean;
  /// A started chat's one move, in the environment picker: Move to Cloud for a chat on this Mac,
  /// Bring Back Local for one a move put on a Cloud machine (the tab menu's same actions), as
  /// `offloads` lists them. None when the host passes none (the floating chat).
  onOffload?(kind: OffloadKind): void;
  /// The moves the app offers this chat now (its right-click menu's, `pane.tabState` `moves`): the
  /// picker offers only these, whatever the machine's kind.
  offloads?: readonly OffloadKind[];
  /// The New Tab page's saved environments, in the environment picker. While one is picked it
  /// alone names where the chat starts: the folder control steps aside. One that is only a folder on
  /// this computer is a folder instead: the folder menu lists and picks it, and names it while it is
  /// picked, with This Mac the machine.
  saved?: SavedEnvironmentRows;
  /// The machine list opened, and every few seconds while it stays open: read the machines and
  /// their status again.
  onRefreshMachines?(): void;
  /// A quiet line in the folder menu: where a new chat starts while it has no folder (its
  /// workspace's private folder).
  folderNote?: string;
  /// A new chat's machine was picked (`local` for this Mac) where no folder of it is known; with a
  /// known folder the pick is `onProject(folder, peer)`.
  onComputer?(computer: string): void;
  /// A Cloud chat whose first send has not run (it failed): a pick of another Cloud machine moves the
  /// chat there and sends its first prompt again (`cloud.repickChat`), rather than starting a new empty
  /// chat through the machine it is on. Resolves false when the app did not take it: the pick then
  /// does what it does for any new chat. Leo, 2026-10-31: he "picked zesty-indigo-lemur in the
  /// machine picker, but the chat stayed on sr2-tunnel-probe".
  onRepick?(machine: RepickMachine): Promise<boolean>;
  /// The account's Cloud machines (cloudMachines.ts); by default the app's list, read again as the
  /// machine list opens. Only a new chat lists them.
  cloudMachines?: readonly CloudMachine[];
  /// A pick of one acpmux does not list: it resumes (paused) or opens; by default through the app.
  onCloudMachine?(machine: CloudMachine): void;
  /// Reports the selected account machine to the pane before its resume/open hint runs. `undefined`
  /// clears a draft target when the picker moves back to a non-Cloud environment.
  onCloudMachinePicked?(machine: CloudMachine | undefined): void;
  /// A new chat's Run as in the environment picker (Persistent or Sandboxed, hq#3367).
  runMode?: RunModeRows;
  /// A trust question takes precedence over an open destination picker.
  closeOnTrustAsk?: boolean;
  /// Gallery seam; the persisted composer setting is used when omitted.
  showMachineLoadWarnings?: boolean;
  /// Gallery seam: the environment control's look (EnvironmentPicker `faceStyle`).
  environmentFace?: EnvironmentFaceStyle;
  /// Gallery seam: how a new chat's strip asks where it runs (StripLayout); `where-machine` ships.
  stripLayout?: StripLayout;
  /// Gallery seam: the cloud toggle's rows' second lines, as ChatGPT Work has them (`cloud-toggle`
  /// only; the shipped picker has no second lines, design/environment-picker.md rule 0).
  runDetails?: RunRowDetails;
  /// Gallery seam, ChatGPT Work's model (not built in cmux: an agent on Cloud runs on its Cloud
  /// machine, with its files there): with Cloud picked, the machine chip's face says which machine the
  /// Cloud agent works on ("works on studio-mac").
  cloudWorksOn?: string;
  /// Gallery seam; the app's Cloud account state (cloudMachines.ts) is used when omitted.
  cloudSignedIn?: boolean;
  /// A new chat's extra folders (extraFolders.ts, acpmux `additionalDirectories`): the folder menu's
  /// Add folder… adds one of the picked machine's folders, and each added one can be removed. The
  /// list is the machine's: another machine picked starts over. `onBrowse` is this Mac's folder
  /// chooser; another machine's folders are its listed ones or a typed path.
  extraFolders?: ExtraFolderControl;
}) {
  const t = useT();
  const composerSettings = useComposerSettings();
  const newChat = !started && onProject !== undefined;
  const accountMachines = useCloudMachines();
  const accountSignedIn = useCloudSignedIn();
  const cloudSignedIn = cloudSignedInSeam ?? accountSignedIn;
  const shownMachines = cloudMachines ?? accountMachines;
  // Every machine acpmux lists (`_acpmux/status` peers) and every host its chats ran on, with each
  // one's transport and state, in both the environment picker and the plain Computer menu; for a
  // new chat, then the account's Cloud machines acpmux does not list (a paused one, say).
  const computers = useMemo(() => {
    // A Cloud machine acpmux has no link to that the account says is paused or resuming reads so,
    // not as a lost link; in a new chat a paused one is a pick that resumes it.
    const listed = withCloudSleep(
      availableComputers(summary, sessions, peers, peerKinds, localName, peerConnected, peerStates, peerResources),
      shownMachines,
      newChat,
    );
    if (!newChat) return listed;
    const detail = t(CONTEXT_LABELS.cloud);
    return withCloudMachines(listed, shownMachines, peers, computerId(summary)).map((row) =>
      isCloudMachineRow(row) ? { ...row, detail } : row,
    );
  }, [
    summary,
    sessions,
    peers,
    peerKinds,
    peerConnected,
    peerStates,
    peerResources,
    localName,
    newChat,
    shownMachines,
    t,
  ]);
  // The list opened, and every few seconds while it is open: acpmux's peers and, for a new chat,
  // the app's Cloud machines are read again. A menu with connect rows reads the Cloud account too,
  // so Sign in for Cloud goes away once the app says the person is signed in (an older chat's
  // menu otherwise never asks, and keeps offering sign-in to someone already signed in).
  const readsCloudAccount = !cloudMachines && (newChat || onConnect !== undefined);
  const onRefreshMachines = readsCloudAccount
    ? () => {
        onRefreshPeers?.();
        void refreshCloudMachines();
      }
    : onRefreshPeers;
  // The plain Computer menu lists them in the picker's sections and order (environments.ts), one
  // line each; a machine a chat cannot start on yet says its state on a second line.
  const loadWarnings = showMachineLoadWarnings ?? composerSettings.showMachineLoadWarnings;
  const warningText = useCallback(
    (resources: MachineResources | undefined) => {
      const warning = machineLoadWarning(resources, loadWarnings);
      if (!warning) return undefined;
      return warning.kind === "load"
        ? t("composer.machineHighLoad", { busy: warning.busy, cores: warning.cores })
        : t("composer.machineLowMemory", { free: formatFreeMemory(warning.freeGB) });
    },
    [loadWarnings, t],
  );
  // The environment picker shows the same warning on a ready machine's row as the plain menu does.
  const pickerComputers = useMemo(
    () =>
      computers.map((computer) => {
        const warning = environmentReady(computer) ? warningText(computer.resources) : undefined;
        return warning ? { ...computer, loadWarning: warning } : computer;
      }),
    [computers, warningText],
  );
  const menuComputers = useMemo(() => {
    const sections = environmentSections(computers);
    return orderEnvironments(computers).map(({ detail: _kind, ...computer }) => {
      const ready = environmentReady(computer);
      const warning = warningText(computer.resources);
      return {
        ...computer,
        section: t(SECTION_LABELS[sections.get(computer.id) ?? "fleet"]),
        // An account Cloud machine acpmux does not list says what a pick does, and is a pick.
        ...(ready
          ? {}
          : {
              ...(isCloudMachineRow(computer) ? {} : { disabled: true }),
              detail: environmentStateLabel(computer),
            }),
        ...(ready && warning ? { warning: true, detail: warning } : {}),
      };
    });
  }, [computers, t, warningText]);
  const initialComputer = computerId(summary);
  // A pick in the Computer menu holds until the chat or its computer changes; then the new chat's
  // own computer shows in the render that shows it (it followed in an effect, a frame late: the
  // wrong computer and no folder for one frame on a local/peer switch). Each change clears the pick,
  // so a pick on one new chat never carries into the next.
  const pickKey = `${summary?.sessionId ?? ""}\u0000${initialComputer}`;
  const [picked, setPicked] = useState<{ key: string; computer?: string }>({ key: pickKey });
  const [browseError, setBrowseError] = useState<string>();
  const browseRequest = useRef(0);
  useEffect(
    () => () => {
      browseRequest.current += 1;
    },
    [],
  );
  if (picked.key !== pickKey) setPicked({ key: pickKey });
  // New Tab's saved environments that are only a folder on this computer: folders, not machines.
  const savedFolders = useMemo(
    () => (newChat ? (saved?.environments ?? []).filter(savedEnvironmentIsFolder) : []),
    [newChat, saved?.environments],
  );
  const savedFolderPick = savedFolders.find((environment) => environment.id === saved?.current);
  // One picked starts the chat on this Mac (NewTabScreen askInEnvironment), whatever machine was
  // picked before it, so this Mac is the machine shown.
  const selectedComputer = savedFolderPick
    ? "local"
    : picked.key === pickKey && picked.computer
      ? picked.computer
      : initialComputer;
  const setSelectedComputer = (computer: string) => setPicked({ key: pickKey, computer });
  // The chat's own machine (not this Mac) is picked, and its folders were listed for it.
  const ownMachine = selectedComputer !== "local" && selectedComputer === initialComputer && Boolean(machineFolders);
  // A Cloud machine picked while it was paused or not yet linked (pickCloudMachine below), until
  // acpmux lists it ready, another machine is picked, or the chat changes. A change drops it for
  // good, so a chat that comes back to the same key (an empty New Tab id) never inherits it; a
  // machine the account stops listing ends it for good too (it does not come back with the
  // machine), and one that failed to start stops it moving.
  // Another machine was picked in the Where menu: the machine control shows and opens (each pick
  // a new request), until the chat or its machine changes.
  const [machineAsk, setMachineAsk] = useState<{ key: string; request: number } | undefined>(undefined);
  // Keyed by the chat, not the pick: New Tab echoes the picked machine back into summary, which
  // changes pickKey, and the open request must survive that echo.
  const askKey = summary?.sessionId ?? "";
  const machineRequest = machineAsk?.key === askKey ? machineAsk.request : undefined;
  const machineAsked = machineRequest !== undefined;
  const [waitingPick, setWaiting] = useState<{ key: string; id: string; name: string } | undefined>(undefined);
  const waitMachine = waitingPick?.key === pickKey ? shownMachines.find((m) => m.id === waitingPick.id) : undefined;
  if (waitingPick && !waitMachine) setWaiting(undefined);
  const waiting = waitMachine ? waitingPick : undefined;
  const waitFailed = waitMachine?.stage === "failed";
  const folders = useMemo(() => {
    const known = availableFolders(summary, sessions, selectedComputer);
    if (selectedComputer === "local") {
      const seen = new Set(known.map((folder) => folder.id));
      for (const environment of savedFolders) {
        const id = normalizeCwd(environment.folder);
        if (!id || seen.has(id)) continue;
        seen.add(id);
        known.push({ id, label: projectLabel(id), detail: id });
      }
    }
    const choices = selectedComputer === "local" ? projectChoices : ownMachine ? machineFolders : undefined;
    if (!choices) return known;
    const projects = choices.map((project) => ({
      id: normalizeCwd(project.cwd)!,
      label: project.label,
      detail: project.cwd,
      ...(project.repo ? { repo: project.repo } : {}),
    }));
    const seen = new Set(projects.map((project) => project.id));
    return [...projects, ...known.filter((folder) => !seen.has(folder.id))];
  }, [summary, sessions, selectedComputer, projectChoices, machineFolders, ownMachine, savedFolders]);
  const summaryFolder = summary?.cwd && computerId(summary) === selectedComputer ? summary.cwd : undefined;
  // A chat in its private agent-home folder has no project yet: the row offers a folder instead.
  const currentFolder = savedFolderPick
    ? normalizeCwd(savedFolderPick.folder)
    : summaryFolder
      ? isAgentHome(summaryFolder)
        ? undefined
        : normalizeCwd(summaryFolder)
      : projectChoices
        ? undefined
        : folders[0]?.id;
  const currentComputer = computers.find((computer) => computer.id === selectedComputer) ?? computers[0];
  // A started chat's picker lists only where it runs, with that machine's warning too.
  const currentPickerComputer =
    pickerComputers.find((computer) => computer.id === selectedComputer) ?? pickerComputers[0];
  // The machine the pick waits for, once acpmux lists it ready: its own row, not the account's.
  const arrived =
    waiting && !waitFailed
      ? computers.find(
          (computer) =>
            !computer.cloudMachine &&
            computer.label.toLowerCase() === waiting.name.toLowerCase() &&
            environmentReady(computer),
        )
      : undefined;
  const arrive = useRef<(id: string) => void>(() => undefined);
  const arrivedId = arrived?.id;
  useEffect(() => {
    if (arrivedId) arrive.current(arrivedId);
  }, [arrivedId]);
  if (!currentComputer && !currentFolder && !projectChoices) return <div className="acpmux-composer-strip" />;
  const readOnly = started || onProject === undefined;
  const sandboxPicked = runMode?.mode === "sandboxed" && !started && !readOnly;
  const cloudPicked = runMode?.mode === "cloud" && !started && !readOnly;
  const newChats = started && onNewChat !== undefined;
  const branch = summary?.branch;
  // The folder control names the repository (projectRepos.ts), and a worktree's branch while no
  // branch control follows it: "cmux · issue-22273", not the worktree folder's own name. A folder
  // inside a checkout always adds its path below it ("cmux · webviews"), branch control or not.
  const currentLocation = currentFolder
    ? (folders.find((folder) => folder.id === currentFolder) ?? {
        id: currentFolder,
        label: projectLabel(currentFolder),
      })
    : undefined;
  const currentRepo = currentLocation ? folderRepo(currentLocation) : undefined;
  const place = !currentLocation
    ? undefined
    : branch
      ? belowCheckout(currentLocation)
      : isMainCheckout(currentLocation)
        ? undefined
        : worktreeName(currentLocation);
  const currentName = currentLocation
    ? currentRepo
      ? place && place !== currentRepo.name
        ? `${currentRepo.name} · ${place}`
        : currentRepo.name
      : projectLabel(currentLocation.id)
    : undefined;
  // A started chat's Choose folder…: the host's folder panel, then a new chat there.
  const browseNewChat =
    onBrowseFolder && onNewChat
      ? () => {
          const request = ++browseRequest.current;
          setBrowseError(undefined);
          void Promise.resolve()
            .then(() => onBrowseFolder())
            .then((cwd) => {
              if (request === browseRequest.current && cwd) onNewChat(cwd);
            })
            .catch((error: unknown) => {
              if (request === browseRequest.current) setBrowseError(browseFailureMessage(error));
            });
        }
      : undefined;
  // An account Cloud machine acpmux does not list runs its machine action (resume or open); the
  // chat cannot start there until acpmux links it. The pick waits for that (`waiting`): the
  // control names the machine as starting, and the chat moves there once its row is ready, so a
  // paused machine is one pick, not a pick, a wait and the same pick again.
  const pickCloudMachine = (id: string) => {
    const machine = computers.find((computer) => computer.id === id)?.cloudMachine;
    if (machine && !readOnly) {
      onCloudMachinePicked?.(machine);
      // Folders are the machine's: the pick drops this machine's at once, not when (or if) it arrives (cmux#34527).
      if (extraFolders?.draft) extraFolders.onChange(undefined);
      onCloudMachine(machine);
      setWaiting({ key: pickKey, id: machine.id, name: machine.name });
    }
    return machine !== undefined;
  };
  const pickComputer = (id: string) => {
    if (pickCloudMachine(id)) return;
    onCloudMachinePicked?.(undefined);
    if (waiting) setWaiting(undefined);
    if (!readOnly && id !== selectedComputer) {
      // Folders are the machine's: another machine starts with none.
      if (extraFolders?.draft && extraFolders.draft.machine !== id) extraFolders.onChange(undefined);
      setSelectedComputer(id);
      const folder = availableFolders(summary, sessions, id)[0]?.id;
      if (folder) onProject?.(folder, id === "local" ? undefined : id);
      else onComputer?.(id);
    }
  };
  arrive.current = (id) => {
    setWaiting(undefined);
    pickComputer(id);
  };
  // The machine control's name: the machine a Cloud pick waits for, as starting, else the current one.
  const waitingName = waiting
    ? `${waiting.name} · ${t(waitFailed ? "switch.failedShort" : "composer.envStarting")}`
    : undefined;
  // A started chat's picker lists only where it runs and its move (EnvironmentPicker `offload`).
  const offload: OffloadKind | undefined = started && environments && onOffload ? offloads[0] : undefined;
  // A first computer is discoverable, including from a started local chat (#27083): with only
  // this Mac listed the picker keeps its connect actions after the chat starts.
  const onboardingConnect = !computers.some((computer) => computer.id !== "local") ? onConnect : undefined;
  const computerDisabled = readOnly && !offload && (started || !onConnect) && !onboardingConnect;
  // The computer control is the environment picker where the surface asks for it.
  const environmentsShown = environments && !computerDisabled;
  const savedRows = environmentsShown && !readOnly ? saved : undefined;
  // A picked saved environment that is only a folder is shown as that folder on This Mac, not here.
  const savedPick = savedRows?.environments.find(
    (environment) => environment.id === savedRows.current && !savedEnvironmentIsFolder(environment),
  );
  // A folder pick is always the folder (the page's project, which Cloud sends and recent projects
  // record), then the saved environment that is only that folder, if there is one.
  const pickFolder = (cwd: string) => {
    onCloudMachinePicked?.(undefined);
    onProject?.(cwd);
    const environment = savedRows && savedFolders.find((candidate) => normalizeCwd(candidate.folder) === cwd);
    if (environment) savedRows.onPick(environment.id);
  };
  // What the environment control names: the row the list checks, so this Mac reads "This Mac" (its
  // own name stays in the tooltip's list row), any other machine its name.
  const placeName =
    waitingName ??
    (savedPick ? savedEnvironmentLabel(savedPick) : undefined) ??
    (currentComputer?.kind === "local" ? t("composer.thisMac") : currentComputer?.label) ??
    t(CONTEXT_LABELS.chooseComputer);
  const pickEnvironment = (id: string) => {
    const repick = onRepick && !readOnly ? repickMachine(computers, id, selectedComputer) : undefined;
    if (onRepick && repick) {
      void onRepick(repick).then(
        (moved) => {
          if (!moved) pickAnyEnvironment(id);
        },
        () => pickAnyEnvironment(id),
      );
      return;
    }
    pickAnyEnvironment(id);
  };
  const pickAnyEnvironment = (id: string) => {
    if (pickCloudMachine(id)) return;
    if (savedRows?.current !== undefined) savedRows.onClear();
    pickComputer(id);
  };
  const folderShown = !savedPick && !(readOnly && !newChats && !currentFolder);
  // The new chat's extra folders on the picked machine (a pick of the chat's own folder is never one).
  // A Cloud or Sandboxed start carries none (cmux#34403), so those modes offer no Add folder… or +N.
  const extraShown =
    extraFolders && !readOnly && !cloudPicked && !sandboxPicked
      ? draftFolders(extraFolders.draft, selectedComputer)
      : undefined;
  const extra: ExtraFolderRows | undefined =
    extraFolders && extraShown
      ? {
          folders: extraShown,
          onAdd: (path) => {
            const next = addExtraFolder(extraShown, path, currentFolder);
            if (next !== extraShown) extraFolders.onChange({ machine: selectedComputer, folders: next });
          },
          onRemove: (path) => {
            const next = removeExtraFolder(extraShown, path);
            if (next !== extraShown)
              extraFolders.onChange(next.length > 0 ? { machine: selectedComputer, folders: next } : undefined);
          },
          ...(selectedComputer === "local" && extraFolders.onBrowse ? { onBrowse: extraFolders.onBrowse } : {}),
        }
      : undefined;
  // The folder control says how many more folders the chat sees: "cmux +2".
  const extraCount = extraShown && extraShown.length > 0 ? ` +${extraShown.length}` : "";
  // The strip's layout: a started chat (or one that cannot change) keeps the one combined control.
  const layout: StripLayout = readOnly || offload ? "combined" : stripLayout;
  // What every environment control shares: the list, the pick, setup and Cloud's run mode.
  const pickerProps = {
    environments: pickerComputers,
    current: selectedComputer,
    onPick: pickEnvironment,
    ...((!started || onboardingConnect) && onConnect ? { onConnect } : {}),
    // A fresh home may not have a Cloud list reply yet: EnvironmentPicker offers Sign in for Cloud
    // (in place of Cloud) only once the app said signed out, never before it knows.
    cloudSignedIn,
    ...(savedRows ? { saved: savedRows } : {}),
    ...(onRefreshMachines ? { onOpen: onRefreshMachines } : {}),
    ...(runMode && !started && !readOnly ? { runMode } : {}),
    closeOnTrustAsk,
    ...(environmentFace ? { faceStyle: environmentFace } : {}),
  };
  // Where it runs: Cloud (the person's machine or a new one, or one picked in Machines…), Sandboxed, another
  // machine (the person's own, SSH), or this Mac. Each machine sits under where it runs, so the Where
  // chip never contradicts the chip beside it.
  const pickedOff = selectedComputer !== "local" && !savedPick;
  const cloudSide =
    cloudPicked || (!sandboxPicked && (waiting !== undefined || (pickedOff && currentComputer?.kind === "cloud")));
  // Leaving Another machine for Cloud, Sandboxed or a saved folder ends its open request, so a later This Mac pick
  // (which may skip the Where onPick when Cloud already cleared the machine) shows no machine chip.
  // A folder-only saved environment picked starts on this Mac: no machine chip either.
  if (machineAsk !== undefined && (cloudSide || sandboxPicked || savedFolderPick !== undefined))
    setMachineAsk(undefined);
  // A saved environment on this Mac is This Mac's; one on an SSH machine is Another machine's.
  const offMac = !cloudSide && !sandboxPicked && (pickedOff || (savedPick !== undefined && savedPick.kind !== "local"));
  const whereName = sandboxPicked
    ? t("composer.sandboxed")
    : cloudSide
      ? t("composer.cloud")
      : offMac
        ? t("composer.anotherMachine")
        : t("composer.thisMac");
  // The Where control's accessible name and tooltip also name the machine, which a narrow strip shows
  // only as an icon.
  const whereValue =
    (offMac || savedPick !== undefined || (cloudSide && !cloudPicked)) && placeName
      ? `${whereName} · ${placeName}`
      : whereName;
  const whereIcon =
    sandboxPicked || cloudSide ? (
      <EnvironmentIcon kind="cloud" />
    ) : offMac ? (
      <AnotherMachineIcon />
    ) : (
      <EnvironmentIcon kind="local" />
    );
  // The third chip: which machine while another machine is the pick (or Another machine was just
  // picked); in `where-machine-always` the machine chip on this Mac too. Cloud has no third chip:
  // Cloud is one pick, and Send reuses the person's machine or makes one (cmux-tui cloud.startChat),
  // with its progress in the chat (CloudStartView). Leo, 2026-11-04: "after you pick Cloud, like,
  // you shouldn't be seeing the new machine situation. Like, we can just get rid of that". Only a
  // Cloud machine picked by name (Machines…) gets the machine chip, naming it, with no New machine.
  const cloudMachinePicked = cloudSide && !cloudPicked && !sandboxPicked;
  const machineShown =
    layout === "where-machine"
      ? offMac || savedPick !== undefined || cloudMachinePicked || (machineAsked && !cloudSide && !sandboxPicked)
      : layout === "where-machine-always"
        ? (!cloudSide && !sandboxPicked) || cloudMachinePicked
        : true;
  const runToggle = environmentsShown && layout === "cloud-toggle";
  // The machine and Cloud chips' face: a server, the machine's name and its live dot (Codex desktop's
  // machine chip). This Mac, where the machine chip shows it, is this Mac's own name; Cloud with no
  // machine picked says Cloud (Send reuses the person's machine or makes one, so no New machine shows;
  // Leo, 2026-11-04); Another machine with none picked asks for one.
  const localMachine = currentComputer?.kind === "local" && !savedPick && !waiting;
  const machineValue =
    cloudPicked && cloudWorksOn
      ? cloudWorksOn
      : cloudPicked || sandboxPicked
        ? t(cloudPicked ? "composer.cloud" : "composer.newMachine")
        : layout === "where-machine" && localMachine
          ? t(CONTEXT_LABELS.chooseMachine)
          : localMachine
            ? (localName ?? t("composer.thisMac"))
            : placeName;
  const machineLive =
    cloudPicked || sandboxPicked || savedPick || waiting || (layout === "where-machine" && localMachine)
      ? undefined
      : currentComputer
        ? environmentReady(currentComputer)
        : undefined;
  // A Cloud machine that sleeps (withCloudSleep): paused is the quiet ring, resuming a spinner.
  const machineSleep =
    machineLive === false && (currentComputer?.state === "paused" || currentComputer?.state === "resuming")
      ? currentComputer.state
      : undefined;
  const machineFace =
    waiting && waitingName && !cloudPicked ? (
      <LocationFace icon={<ServerIcon />} value={waitingName} chevron />
    ) : (
      <LocationFace
        icon={
          cloudPicked && cloudWorksOn ? (
            <EnvironmentIcon kind="local" />
          ) : layout === "cloud-toggle" ? (
            <EnvironmentIcon
              kind={cloudPicked ? "cloud" : (currentComputer?.kind ?? "local")}
              name={currentComputer?.label}
            />
          ) : (
            <ServerIcon />
          )
        }
        value={machineValue}
        chevron
        {...(machineLive !== undefined ? { live: machineLive } : {})}
        {...(machineSleep ? { sleep: machineSleep } : {})}
      />
    );
  // The one combined control's face (a started chat, and the `combined` arm): as before.
  const combinedFace =
    waiting && waitingName ? (
      <LocationFace icon={<EnvironmentIcon kind="cloud" name={waiting.name} />} value={waitingName} chevron />
    ) : (
      <LocationFace
        icon={
          <EnvironmentIcon
            kind={savedPick?.kind ?? currentComputer?.kind ?? "local"}
            name={savedPick ? undefined : currentComputer?.label}
          />
        }
        value={placeName}
        chevron
      />
    );
  // Another machine: the first of the person's own machines a chat can start on is the pick (so the
  // strip always says where the chat starts), and the machine chip opens to change it; with none of
  // them listed, Add Machine….
  const anotherMachine = () => {
    const others = orderEnvironments(pickerComputers).filter(
      (computer) => computer.kind !== "local" && computer.kind !== "cloud",
    );
    if (others.length === 0) {
      onConnect?.("addMachine");
      return;
    }
    const first = others.find(environmentReady);
    if (first && !offMac) pickEnvironment(first.id);
    setMachineAsk({ key: askKey, request: (machineAsk?.request ?? 0) + 1 });
  };
  return (
    <div className="acpmux-composer-strip">
      <div className="acpmux-composer-context" data-readonly={readOnly ? "true" : undefined}>
        <div className="acpmux-location-leading">
          {!folderShown ? null : !readOnly && selectedComputer === "local" && projectChoices ? (
            <FolderPopover
              label={t(CONTEXT_LABELS.folder)}
              menu="Location"
              face={
                <LocationFace
                  icon={
                    currentLocation ? (
                      <ProjectBadge
                        project={{
                          cwd: currentLocation.id,
                          label: currentName ?? currentLocation.label,
                          ...(currentLocation.repo ? { repo: currentLocation.repo } : {}),
                        }}
                      />
                    ) : (
                      <FolderIcon />
                    )
                  }
                  value={
                    (currentName
                      ? currentName
                      : noProject
                        ? t(CONTEXT_LABELS.noProject)
                        : t(CONTEXT_LABELS.chooseFolder)) + extraCount
                  }
                  chevron
                  middle={currentFolder !== undefined}
                  dim={!currentName && !noProject}
                />
              }
              folders={folders}
              current={currentFolder}
              onPick={pickFolder}
              onBrowse={onBrowseProject}
              onNoProject={onNoProject}
              noProject={noProject && !currentFolder}
              onNewWorktree={currentFolder && onNewWorktree ? () => onNewWorktree(currentFolder) : undefined}
              localName={localName}
              peers={peers}
              {...(folderNote && !currentFolder ? { note: folderNote } : {})}
              {...(extra ? { extra } : {})}
            />
          ) : (
            <LocationPicker
              label={t(CONTEXT_LABELS.folder)}
              menu="Location"
              value={(currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)) + extraCount}
              options={folders}
              selected={currentFolder}
              disabled={readOnly && !newChats}
              icon={<FolderIcon />}
              middle={currentFolder !== undefined}
              allowPath
              {...(extra ? { extra } : {})}
              onBrowse={newChats ? browseNewChat : undefined}
              extras={
                newChats && currentFolder
                  ? [
                      {
                        id: "newChatHere",
                        label: t(CONTEXT_LABELS.newChatHere),
                        onSelect: () => {
                          browseRequest.current += 1;
                          onNewChat?.(currentFolder);
                        },
                      },
                    ]
                  : undefined
              }
              onPick={(cwd) => {
                if (newChats) {
                  browseRequest.current += 1;
                  onNewChat?.(cwd);
                } else if (!readOnly)
                  onProject?.(cwd, selectedComputer === "local" || ownMachine ? undefined : selectedComputer);
              }}
            />
          )}
          {environmentsShown ? (
            layout === "combined" ? (
              <EnvironmentPicker
                {...pickerProps}
                label={t(CONTEXT_LABELS.environment)}
                menu="Computer"
                value={sandboxPicked ? t("composer.sandboxed") : cloudPicked ? t("composer.cloud") : placeName}
                face={
                  // Sandboxed (hq#3367) or Cloud picked: the control names it where the machine was.
                  sandboxPicked || cloudPicked ? (
                    <LocationFace
                      icon={<EnvironmentIcon kind="cloud" />}
                      value={t(sandboxPicked ? "composer.sandboxed" : "composer.cloud")}
                      chevron
                    />
                  ) : (
                    combinedFace
                  )
                }
                environments={offload && currentPickerComputer ? [currentPickerComputer] : pickerComputers}
                {...(offload && onOffload ? { offload, onOffload } : {})}
              />
            ) : layout === "cloud-toggle" ? (
              <EnvironmentPicker
                {...pickerProps}
                label={t(CONTEXT_LABELS.environment)}
                menu="Computer"
                value={machineValue}
                face={machineFace}
                rows="machines"
                includeLocal
              />
            ) : (
              <>
                <EnvironmentPicker
                  {...pickerProps}
                  label={t(CONTEXT_LABELS.environment)}
                  menu="Computer"
                  value={whereValue}
                  face={<LocationFace icon={whereIcon} value={whereName} chevron />}
                  rows="where"
                  onAnother={anotherMachine}
                  onPick={(id) => {
                    setMachineAsk(undefined);
                    pickEnvironment(id);
                  }}
                />
                {machineShown && (
                  <EnvironmentPicker
                    {...pickerProps}
                    label={t(CONTEXT_LABELS.machine)}
                    menu="Machine"
                    value={machineValue}
                    face={machineFace}
                    rows="machines"
                    includeLocal={layout === "where-machine-always"}
                    ownOnly={!cloudMachinePicked}
                    digits={false}
                    setupMenu={false}
                    {...(machineRequest !== undefined ? { openRequest: machineRequest } : {})}
                  />
                )}
              </>
            )
          ) : (
            <LocationPicker
              label={t(CONTEXT_LABELS.computer)}
              menu="Computer"
              kind="computer"
              icon={
                <ComputerIcon
                  name={waiting?.name ?? (currentComputer?.kind === "local" ? undefined : currentComputer?.label)}
                />
              }
              value={waitingName ?? currentComputer?.label ?? t(CONTEXT_LABELS.chooseComputer)}
              options={menuComputers}
              selected={selectedComputer}
              disabled={computerDisabled}
              {...(onRefreshMachines ? { onOpen: onRefreshMachines } : {})}
              extras={
                onboardingConnect
                  ? [
                      {
                        id: "addMachine",
                        label: t(CONTEXT_LABELS.addComputer),
                        onSelect: () => onboardingConnect?.("addMachine"),
                      },
                      ...(cloudSignedIn === false
                        ? [
                            {
                              id: "cloudSignIn",
                              label: t("composer.cloudSignIn"),
                              onSelect: () => onboardingConnect?.("cloudSignIn"),
                            },
                          ]
                        : []),
                      {
                        id: "cloud",
                        label: t(CONTEXT_LABELS.newCloudMachine),
                        // What one gives, as the environment picker's row says it.
                        detail: t("composer.newCloudMachineDetail"),
                        onSelect: () => onboardingConnect?.("cloud"),
                      },
                    ]
                  : !started && onConnect && !connectOnlyWhenEmpty
                    ? [
                        ...(cloudSignedIn === false
                          ? [
                              {
                                id: "cloudSignIn",
                                label: t("composer.cloudSignIn"),
                                onSelect: () => onConnect("cloudSignIn"),
                              },
                            ]
                          : []),
                        { id: "ssh", label: t(CONTEXT_LABELS.connectSSH), onSelect: () => onConnect("ssh") },
                        {
                          id: "cloud",
                          label: t(CONTEXT_LABELS.newCloudMachine),
                          detail: t("composer.newCloudMachineDetail"),
                          onSelect: () => onConnect("cloud"),
                        },
                      ]
                    : undefined
              }
              closeOnTrustAsk={closeOnTrustAsk}
              onPick={pickComputer}
            />
          )}
        </div>
        {browseError && browseNewChat && (
          <BrowseFailure error={browseError} onRetry={browseNewChat} onDismiss={() => setBrowseError(undefined)} />
        )}
        {runToggle && (
          <EnvironmentPicker
            {...pickerProps}
            label={t("composer.whereRun")}
            menu="Run"
            value={whereName}
            face={<LocationFace icon={whereIcon} value={whereName} chevron={false} />}
            faceStyle="icon"
            rows="run"
            {...(runDetails ? { runDetails } : {})}
            digits={false}
            setupMenu={false}
          />
        )}
        {branch && <BranchPicker branch={branch} />}
      </div>
    </div>
  );
}

function BranchPicker({ branch }: { branch: string }) {
  const { control, anchor, open, setOpen, side, flip } = useLocationPopover();
  return (
    <span ref={control} className="acpmux-location-picker">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-location-button ui-ghost ui-ghost-sm" label={t("changes.scope.branch")}>
          <LocationFace icon={<BranchIcon />} value={branch} chevron />
        </MenuButton>
        <MenuPopup side={side} flip={flip} anchor={anchor} className="acpmux-menu acpmux-location-menu" align="end">
          <MenuRadioGroup value={branch} onValueChange={() => undefined}>
            <MenuRadioItem value={branch} disabled className="acpmux-menu-item">
              <span className="acpmux-menu-text">
                <span className="acpmux-menu-label">{branch}</span>
              </span>
            </MenuRadioItem>
          </MenuRadioGroup>
        </MenuPopup>
      </Menu>
    </span>
  );
}

function BranchIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      aria-hidden="true"
    >
      <circle cx="4" cy="3" r="1.5" />
      <circle cx="4" cy="13" r="1.5" />
      <circle cx="12" cy="13" r="1.5" />
      <path d="M4 4.5v5A3.5 3.5 0 0 0 7.5 13H10.5M4 6.5A3.5 3.5 0 0 1 7.5 3H10" />
    </svg>
  );
}

/// The machine a chat runs on: its peer (an SSH or Cloud machine), else its Cloud host, else this Mac.
function computerId(summary?: Summary): string {
  return summary?.peer || (summary?.hostKind === "cloud" && summary.host) || "local";
}

function availableComputers(
  summary: Summary | undefined,
  sessions: Session[],
  peers: string[],
  peerKinds: Record<string, "ssh" | "cloud">,
  localName: string | undefined,
  peerConnected: Record<string, boolean>,
  peerStates: Record<string, string>,
  peerResources: Record<string, MachineResources>,
): Computer[] {
  const localLabel =
    localName || (summary?.hostKind === "local" && summary.host ? summary.host : t(CONTEXT_LABELS.local));
  const computers: Computer[] = [{ id: "local", label: localLabel, kind: "local" }];
  const current = summary ? [summary] : [];
  for (const machine of knownMachines(peers, sessions, peerKinds, current, peerConnected, peerStates)) {
    const detail = t(machine.kind === "ssh" ? "composer.envSSH" : CONTEXT_LABELS.cloud);
    computers.push({
      ...machine,
      detail,
      ...(peerResources[machine.id] ? { resources: peerResources[machine.id] } : {}),
    });
  }
  return computers;
}

function formatFreeMemory(gb: number): string {
  return Number.isInteger(gb) ? String(gb) : gb.toFixed(1);
}

function availableFolders(summary: Summary | undefined, sessions: Session[], computer: string): Location[] {
  const seen = new Set<string>();
  const folders: Location[] = [];
  const add = (cwd?: string) => {
    const id = normalizeCwd(cwd);
    // A private agent-home folder is never offered by its id.
    if (!id || seen.has(id) || isAgentHome(id)) return;
    seen.add(id);
    folders.push({ id, label: projectLabel(id), detail: id });
  };
  if (summary && computerId(summary) === computer) add(summary.cwd);
  for (const session of sessions) {
    const sessionComputer = session.peer ?? (session.hostKind === "cloud" ? session.host : "local");
    if (sessionComputer === computer) add(session.cwd);
  }
  return folders;
}

function normalizeCwd(cwd?: string): string | undefined {
  if (!cwd) return undefined;
  const normalized = cwd.replace(/\/+$/, "");
  return normalized || (cwd.startsWith("/") ? "/" : cwd);
}

/// What every location control shows: an optional icon, the name (cut with an ellipsis, never
/// wrapped) and, on a control that opens a menu, a chevron. One look for the whole row. A folder's
/// name (`middle`) is cut in the middle, so its end survives: "atl…web", never "atla…" (design
/// panel, compact composer).
function LocationFace({
  icon,
  value,
  chevron,
  middle = false,
  live,
  sleep,
  dim = false,
}: {
  icon?: React.ReactNode;
  value: string;
  chevron: boolean;
  middle?: boolean;
  /// A machine's live dot (the machine control): filled while a chat can start there, a ring when not.
  live?: boolean;
  /// A machine that is not live because its Cloud machine sleeps: paused keeps the ring and says
  /// Paused, resuming draws a spinner in the dot's place and says Resuming (never a pulsing dot).
  sleep?: "paused" | "resuming";
  /// An empty choice ("Choose project"): dimmed until something is picked.
  dim?: boolean;
}) {
  const [head, tail] = middle ? splitForMiddleTruncation(value) : [value, ""];
  return (
    <>
      {icon}
      {tail ? (
        <span className="acpmux-location-label" data-middle="">
          <span className="acpmux-location-head">{head}</span>
          <span className="acpmux-location-tail">{tail}</span>
        </span>
      ) : (
        <span className="acpmux-location-label" data-dim={dim ? "" : undefined}>
          {value}
        </span>
      )}
      {live !== undefined && sleep === "resuming" && (
        <span className="acpmux-env-live" data-sleep="resuming">
          <Spinner size={12} loading className="acpmux-env-live-spinner" />
          <span className="acpmux-env-status-text">{t("composer.envResuming")}</span>
        </span>
      )}
      {live !== undefined && sleep !== "resuming" && (
        <span className="acpmux-env-live" data-connected={String(live)} data-sleep={sleep}>
          <span className="acpmux-env-status-text">
            {t(live ? "composer.envConnected" : sleep === "paused" ? "composer.envPaused" : "composer.envNotConnected")}
          </span>
        </span>
      )}
      {chevron && (
        <span className="ui-ghost-icon" aria-hidden="true">
          <ChevronIcon />
        </span>
      )}
    </>
  );
}

/// A name split for a cut in the middle: the head takes the ellipsis, the tail always shows. Names
/// under 7 characters are not split (they fit, or a cut would leave nothing to read). The tail is
/// the name's last word when that word is 3 to 10 characters ("atlas-web-checkout-service" reads
/// "atlas-we…service", never "…ervice"); otherwise a third of the name, 3 to 6 characters.
export function splitForMiddleTruncation(value: string): [string, string] {
  const chars = Array.from(value);
  if (chars.length < 7) return [value, ""];
  const separator = Math.max(...["-", "_", ".", " "].map((mark) => chars.lastIndexOf(mark)));
  const word = chars.length - 1 - separator;
  const tail = separator > 0 && word >= 3 && word <= 10 ? word : Math.min(6, Math.max(3, Math.floor(chars.length / 3)));
  return [chars.slice(0, -tail).join(""), chars.slice(-tail).join("")];
}

function FolderIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon ui-ghost-icon"
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M1.9 4.6c0-.8.6-1.4 1.4-1.4h2.6l1.5 1.6h5.3c.8 0 1.4.6 1.4 1.4v5.6c0 .8-.6 1.4-1.4 1.4H3.3c-.8 0-1.4-.6-1.4-1.4Z" />
    </svg>
  );
}

/// The computer chip's icon, in another machine's own color (machineColor); this Mac's stays quiet.
function ComputerIcon({ name }: { name?: string }) {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon ui-ghost-icon"
      style={name ? { color: machineColor(name) } : undefined}
      width={14}
      height={14}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <rect x="3" y="3.5" width="10" height="7" rx="1.2" />
      <path d="M1.75 12.5h12.5" strokeLinecap="round" />
    </svg>
  );
}

/// Machines and folders use the shared searchable Combobox. Only the folder picker accepts a
/// typed absolute or ~/ path; machines always submit a listed destination.
function LocationPicker({
  label,
  menu,
  value,
  options,
  selected,
  disabled,
  icon,
  middle = false,
  kind,
  allowPath = false,
  onBrowse,
  extras,
  onPick,
  onOpen,
  closeOnTrustAsk = false,
  extra,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  value: string;
  /// In order; a row with a `section` heads it when the row above (as shown) is in another.
  options: Location[];
  selected?: string;
  disabled: boolean;
  icon?: React.ReactNode;
  /// The name is cut in the middle (a folder's).
  middle?: boolean;
  /// "computer": the picker whose name gives way to its icon in a narrow strip.
  kind?: "computer";
  allowPath?: boolean;
  /// The folder popover's last row, Choose folder…: the host's folder panel.
  onBrowse?(): void;
  /// Rows after the choices that run something instead of picking (the connect flows).
  extras?: { id: string; label: string; detail?: string; onSelect(): void }[];
  onPick(id: string): void;
  /// The list opened, and every few seconds while it stays open (useMachineRefresh).
  onOpen?(): void;
  /// A trust question takes precedence over an open destination picker.
  closeOnTrustAsk?: boolean;
  /// A new chat's extra folders on this machine (extraFolders.ts): Add folder… turns the list into a
  /// pick of one more folder of it, and the ones added are listed under it.
  extra?: ExtraFolderRows;
}) {
  const [query, setQuery] = useState("");
  const [addingExtra, setAddingExtra] = useState(false);
  const { control, anchor, open, setOpen: setPopoverOpen, side, flip } = useLocationPopover();
  const setOpen = (next: boolean) => {
    if (next && closeOnTrustAsk) return;
    setPopoverOpen(next);
    if (!next) setAddingExtra(false);
  };
  const changeOpen = (next: boolean) => {
    setOpen(next);
    if (!next) setQuery("");
  };
  const press = usePopoverTrigger(open, changeOpen);
  const trigger = useRef<HTMLButtonElement>(null);
  useLocationOpener(disabled ? undefined : menu, () => setOpen(true));
  useEffect(() => {
    if (!closeOnTrustAsk || !open) return;
    setPopoverOpen(false);
    setQuery("");
  }, [closeOnTrustAsk, open, setPopoverOpen]);
  useMachineRefresh(open && !disabled, onOpen);
  // A folder list names duplicates apart by a short suffix, its path only on hover (projectSuffix.ts).
  const suffixes = useMemo(
    () => (allowPath ? projectSuffixes(options.map((option) => ({ cwd: option.id, label: option.label }))) : undefined),
    [allowPath, options],
  );
  const extraFolders = extra?.folders;
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return options.filter(
      (option) =>
        // While adding, the chat's folder and the ones already added are not offered again.
        !(addingExtra && (option.id === selected || extraFolders?.includes(option.id))) &&
        words.every((word) =>
          [option.label, option.detail ?? "", suffixes?.get(option.id) ?? ""].join(" ").toLowerCase().includes(word),
        ),
    );
  }, [options, query, suffixes, addingExtra, selected, extraFolders]);
  // Add folder… gives the menu a fresh field (the Combobox's key): the keyboard stays in it.
  useEffect(() => {
    if (!addingExtra) return;
    control.current?.ownerDocument
      .querySelector<HTMLInputElement>(".acpmux-location-menu .acpmux-location-search")
      ?.focus();
  }, [addingExtra, control]);
  if (disabled)
    return (
      <span className="acpmux-location-picker" data-kind={kind}>
        <span
          className="acpmux-location-readonly"
          aria-label={label + ": " + value}
          title={label + ": " + (allowPath && selected ? selected : value)}
        >
          <LocationFace icon={icon} value={value} chevron={false} middle={middle} />
        </span>
      </span>
    );
  const pick = (id: string) => {
    if (addingExtra) extra?.onAdd(id);
    else onPick(id);
    setOpen(false);
    setQuery("");
  };
  const button = <LocationFace icon={icon} value={value} chevron middle={middle} />;
  // The folder field suggests folder paths; a typed path that names none is offered as typed.
  const typedPath = allowPath && /^(?:\/|~\/)/.test(query.trim()) ? query.trim() : undefined;
  const suggestions = shown.map((option) => option.id);
  if (typedPath && !suggestions.includes(typedPath)) suggestions.push(typedPath);
  return (
    // tooltip-allow: the computer chip shows only its icon in narrow panes.
    <span
      ref={control}
      className="acpmux-location-picker"
      data-kind={kind}
      title={kind === "computer" ? label + ": " + value : undefined}
    >
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        aria-label={kind === "computer" ? label + ": " + value : label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {button}
      </button>
      <Popover
        open={open}
        onOpenChange={changeOpen}
        anchor={open ? anchor : null}
        label={label}
        className="acpmux-menu acpmux-location-menu"
        side={side}
        flip={flip}
      >
        <Combobox
          key={addingExtra ? "extra" : "pick"}
          suggestions={suggestions}
          onQuery={setQuery}
          onSubmit={(id) => {
            const option = options.find((candidate) => candidate.id === id);
            if (option?.disabled) return;
            if (option || (allowPath && /^(?:\/|~\/)/.test(id))) pick(id);
          }}
          onCancel={() => changeOpen(false)}
          cancelOnBlur={false}
          autoHighlight={kind === "computer" ? "always" : false}
          // Escape closes back onto the folder chip (escapeFocus.ts).
          onCommand={(event) => {
            if (event.key === "Escape") focusAfterEscape(trigger.current);
          }}
          label={addingExtra ? t("composer.addFolderSearch") : label}
          placeholder={
            addingExtra
              ? t("composer.addFolderSearch")
              : t(allowPath ? CONTEXT_LABELS.folderSearch : "composer.environmentSearch")
          }
          inputClassName="acpmux-location-search block h-8 w-full min-w-60 appearance-none border-0 bg-transparent px-2 font-[inherit] text-fg outline-none placeholder:text-muted"
          listClassName="acpmux-location-folders m-0 list-none border-t-[0.5px] border-edge p-0 pt-1 [&:not([hidden])]:mt-1"
          itemClassName="acpmux-menu-item rounded-lg data-[highlighted]:bg-hover"
          itemLabel={(id) => {
            const option = options.find((candidate) => candidate.id === id);
            return allowPath ? [option?.label, id].filter(Boolean).join(" ") : (option?.label ?? id);
          }}
          completionText={(id) => (allowPath ? id : (options.find((option) => option.id === id)?.label ?? id))}
          isItemCurrent={(id) => !addingExtra && id === selected}
          renderItem={(path) => {
            const folder = options.find((option) => option.id === path);
            const suffix = suffixes?.get(path);
            const index = shown.indexOf(folder!);
            const section =
              folder?.section && (index <= 0 || shown[index - 1]!.section !== folder.section)
                ? folder.section
                : undefined;
            return (
              // tooltip-allow: the row shows the folder's name; the tooltip is its full path
              <span
                className="acpmux-menu-text acpmux-location-name"
                title={path}
                data-section={section}
                data-first-section={section && index === 0 ? "" : undefined}
                data-ready={folder?.disabled ? "false" : undefined}
                data-warning={folder?.warning ? "true" : undefined}
                aria-disabled={folder?.disabled ? true : undefined}
              >
                <span className="acpmux-menu-label">{folder?.label ?? path}</span>
                {!allowPath && folder?.detail && <span className="acpmux-menu-description">{folder.detail}</span>}
                {suffix && (
                  <>
                    {" "}
                    <span className="acpmux-location-suffix-dot" aria-hidden="true">
                      ·
                    </span>{" "}
                    <span className="acpmux-location-suffix">{suffix}</span>
                  </>
                )}
              </span>
            );
          }}
          inline
          keepHeight
        />
        {extra && !addingExtra && (
          <>
            <ExtraFolderList folders={extra.folders} onRemove={extra.onRemove} />
            <hr className="ui-separator" />
            <button
              type="button"
              className="acpmux-menu-item acpmux-location-choose"
              data-add-folder=""
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => {
                setQuery("");
                setAddingExtra(true);
              }}
            >
              {t("composer.addFolder")}
            </button>
          </>
        )}
        {extras && extras.length > 0 && <hr className="ui-separator" />}
        {extras?.map((extra) => (
          <button
            key={extra.id}
            type="button"
            className="acpmux-menu-item acpmux-location-choose"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              setOpen(false);
              setQuery("");
              extra.onSelect();
            }}
          >
            {extra.detail ? (
              <span className="acpmux-menu-text">
                <span className="acpmux-menu-label">{extra.label}</span>
                <span className="acpmux-menu-description">{extra.detail}</span>
              </span>
            ) : (
              extra.label
            )}
          </button>
        ))}
        {onBrowse && (
          <>
            <hr className="ui-separator" />
            <button
              type="button"
              className="acpmux-menu-item acpmux-location-choose"
              // The field keeps the keyboard: its blur closes the picker before the click.
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => {
                setOpen(false);
                setQuery("");
                onBrowse();
              }}
            >
              {t(CONTEXT_LABELS.chooseFolderMenu)}
            </button>
          </>
        )}
      </Popover>
    </span>
  );
}
