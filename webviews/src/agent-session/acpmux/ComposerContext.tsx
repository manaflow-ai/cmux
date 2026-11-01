import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { Popover } from "../../ui/Popover";
import { BrowseFailure, browseFailureMessage } from "./BrowseFailure";
import type { AcpmuxSnapshot } from "./model";
import { ChevronIcon } from "./ComposerPickers";
import {
  EnvironmentIcon,
  EnvironmentPicker,
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
  type CloudMachine,
} from "./cloudMachines";
import {
  environmentReady,
  environmentSections,
  knownMachines,
  orderEnvironments,
  type ConnectKind,
  type EnvironmentKind,
  type OffloadKind,
} from "./environments";
import { FolderPopover } from "./FolderPopover";
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
  noProject: "composer.noProject",
  environment: "composer.environment",
} as const;

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
  cloudMachines,
  onCloudMachine = (machine) => void runCloudMachine(machine),
  runMode,
  closeOnTrustAsk = false,
  showMachineLoadWarnings,
  environmentFace,
  cloudSignedIn: cloudSignedInSeam,
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
  /// alone names where the chat starts: the folder control steps aside.
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
  /// The account's Cloud machines (cloudMachines.ts); by default the app's list, read again as the
  /// machine list opens. Only a new chat lists them.
  cloudMachines?: readonly CloudMachine[];
  /// A pick of one acpmux does not list: it resumes (paused) or opens; by default through the app.
  onCloudMachine?(machine: CloudMachine): void;
  /// A new chat's Run as in the environment picker (Persistent or Sandboxed, hq#3367).
  runMode?: RunModeRows;
  /// A trust question takes precedence over an open destination picker.
  closeOnTrustAsk?: boolean;
  /// Gallery seam; the persisted composer setting is used when omitted.
  showMachineLoadWarnings?: boolean;
  /// Gallery seam: the environment control's look (EnvironmentPicker `faceStyle`).
  environmentFace?: EnvironmentFaceStyle;
  /// Gallery seam; the app's Cloud account state (cloudMachines.ts) is used when omitted.
  cloudSignedIn?: boolean;
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
    const listed = availableComputers(
      summary,
      sessions,
      peers,
      peerKinds,
      localName,
      peerConnected,
      peerStates,
      peerResources,
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
  const selectedComputer = picked.key === pickKey && picked.computer ? picked.computer : initialComputer;
  const setSelectedComputer = (computer: string) => setPicked({ key: pickKey, computer });
  // The chat's own machine (not this Mac) is picked, and its folders were listed for it.
  const ownMachine = selectedComputer !== "local" && selectedComputer === initialComputer && Boolean(machineFolders);
  // A Cloud machine picked while it was paused or not yet linked (pickCloudMachine below), until
  // acpmux lists it ready, another machine is picked, or the chat changes. A change drops it for
  // good, so a chat that comes back to the same key (an empty New Tab id) never inherits it; a
  // machine the account stops listing ends it for good too (it does not come back with the
  // machine), and one that failed to start stops it moving.
  const [waitingPick, setWaiting] = useState<{ key: string; id: string; name: string } | undefined>(undefined);
  const waitMachine = waitingPick?.key === pickKey ? shownMachines.find((m) => m.id === waitingPick.id) : undefined;
  if (waitingPick && !waitMachine) setWaiting(undefined);
  const waiting = waitMachine ? waitingPick : undefined;
  const waitFailed = waitMachine?.stage === "failed";
  const folders = useMemo(() => {
    const known = availableFolders(summary, sessions, selectedComputer);
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
  }, [summary, sessions, selectedComputer, projectChoices, machineFolders, ownMachine]);
  const summaryFolder = summary?.cwd && computerId(summary) === selectedComputer ? summary.cwd : undefined;
  // A chat in its private agent-home folder has no project yet: the row offers a folder instead.
  const currentFolder = summaryFolder
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
      onCloudMachine(machine);
      setWaiting({ key: pickKey, id: machine.id, name: machine.name });
    }
    return machine !== undefined;
  };
  const pickComputer = (id: string) => {
    if (pickCloudMachine(id)) return;
    if (waiting) setWaiting(undefined);
    if (!readOnly && id !== selectedComputer) {
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
  const savedPick = savedRows?.environments.find((environment) => environment.id === savedRows.current);
  // What the environment control names: the row the list checks, so this Mac reads "This Mac" (its
  // own name stays in the tooltip's list row), any other machine its name.
  const placeName =
    waitingName ??
    savedPick?.name ??
    (currentComputer?.kind === "local" ? t("composer.thisMac") : currentComputer?.label) ??
    t(CONTEXT_LABELS.chooseComputer);
  const pickEnvironment = (id: string) => {
    if (pickCloudMachine(id)) return;
    if (savedRows?.current !== undefined) savedRows.onClear();
    pickComputer(id);
  };
  const folderShown = !savedPick && !(readOnly && !newChats && !currentFolder);
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
                    currentName ? currentName : noProject ? t(CONTEXT_LABELS.noProject) : t(CONTEXT_LABELS.chooseFolder)
                  }
                  chevron
                  middle={currentFolder !== undefined}
                />
              }
              folders={folders}
              current={currentFolder}
              onPick={(cwd) => onProject?.(cwd)}
              onBrowse={onBrowseProject}
              onNoProject={onNoProject}
              noProject={noProject && !currentFolder}
              onNewWorktree={currentFolder && onNewWorktree ? () => onNewWorktree(currentFolder) : undefined}
              localName={localName}
              peers={peers}
              {...(folderNote && !currentFolder ? { note: folderNote } : {})}
            />
          ) : (
            <LocationPicker
              label={t(CONTEXT_LABELS.folder)}
              menu="Location"
              value={currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)}
              options={folders}
              selected={currentFolder}
              disabled={readOnly && !newChats}
              icon={<FolderIcon />}
              middle={currentFolder !== undefined}
              allowPath
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
            <EnvironmentPicker
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
                ) : waiting && waitingName ? (
                  <LocationFace
                    icon={<EnvironmentIcon kind="cloud" name={waiting.name} />}
                    value={waitingName}
                    chevron
                  />
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
                )
              }
              {...(environmentFace ? { faceStyle: environmentFace } : {})}
              environments={offload && currentPickerComputer ? [currentPickerComputer] : pickerComputers}
              current={selectedComputer}
              onPick={pickEnvironment}
              {...(offload && onOffload ? { offload, onOffload } : {})}
              {...((!started || onboardingConnect) && onConnect ? { onConnect } : {})}
              // A fresh home may not have a Cloud list reply at all. EnvironmentPicker treats only
              // an explicit true as signed in, so it can offer the existing sign-in action there.
              cloudSignedIn={cloudSignedIn}
              {...(savedRows ? { saved: savedRows } : {})}
              {...(onRefreshMachines ? { onOpen: onRefreshMachines } : {})}
              {...(runMode && !started && !readOnly ? { runMode } : {})}
              closeOnTrustAsk={closeOnTrustAsk}
            />
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
                      ...(cloudSignedIn !== true
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
                        ...(cloudSignedIn !== true
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
}: {
  icon?: React.ReactNode;
  value: string;
  chevron: boolean;
  middle?: boolean;
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
        <span className="acpmux-location-label">{value}</span>
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
}) {
  const [query, setQuery] = useState("");
  const { control, anchor, open, setOpen: setPopoverOpen, side, flip } = useLocationPopover();
  const setOpen = (next: boolean) => {
    if (next && closeOnTrustAsk) return;
    setPopoverOpen(next);
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
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return options.filter((option) =>
      words.every((word) =>
        [option.label, option.detail ?? "", suffixes?.get(option.id) ?? ""].join(" ").toLowerCase().includes(word),
      ),
    );
  }, [options, query, suffixes]);
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
    onPick(id);
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
          label={label}
          placeholder={t(allowPath ? CONTEXT_LABELS.folderSearch : "composer.environmentSearch")}
          inputClassName="acpmux-location-search block h-8 w-full min-w-60 appearance-none border-0 bg-transparent px-2 font-[inherit] text-fg outline-none placeholder:text-muted"
          listClassName="acpmux-location-folders m-0 list-none border-t-[0.5px] border-edge p-0 pt-1 [&:not([hidden])]:mt-1"
          itemClassName="acpmux-menu-item rounded-lg data-[highlighted]:bg-hover"
          itemLabel={(id) => {
            const option = options.find((candidate) => candidate.id === id);
            return allowPath ? [option?.label, id].filter(Boolean).join(" ") : (option?.label ?? id);
          }}
          completionText={(id) => (allowPath ? id : (options.find((option) => option.id === id)?.label ?? id))}
          isItemCurrent={(id) => id === selected}
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
