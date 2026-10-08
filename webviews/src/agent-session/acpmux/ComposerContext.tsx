import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";
import { Popover, type UiVirtualAnchor } from "../../ui/Popover";
import type { AcpmuxSnapshot } from "./model";
import { ChevronIcon } from "./ComposerPickers";
import type { Project } from "./ProjectChooser";
import { ProjectBadge } from "./ProjectBadge";
import { isAgentHome, projectLabel } from "./sessionList";
import { translate as t } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { usePopoverTrigger } from "./popoverTrigger";

export const CONTEXT_LABELS = {
  computer: "composer.computer",
  folder: "composer.folder",
  local: "composer.thisMac",
  chooseComputer: "composer.chooseComputer",
  chooseFolder: "composer.chooseFolder",
  chooseFolderMenu: "composer.chooseFolderMenu",
  cloud: "composer.cloud",
  connectSSH: "composer.connectSSH",
  connectCloud: "composer.connectCloud",
} as const;

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
type Session = AcpmuxSnapshot["sessions"][number];
type Location = { id: string; label: string; detail?: string };

/// The location tray attached below the composer. New chats can choose a local or Cloud
/// computer and one of its known folders. Once the first turn starts the computer is a label and
/// the folder moves the chat (`onMove`), except while a turn runs.
export function ComposerContext({
  summary,
  sessions = [],
  peers = [],
  started = false,
  onProject,
  projectChoices,
  onBrowseProject,
  localName,
  movedTo,
  onMove,
  busy = false,
  onConnect,
}: {
  summary?: Summary;
  sessions?: Session[];
  peers?: string[];
  started?: boolean;
  onProject?(cwd: string, peer?: string): void;
  projectChoices?: Project[];
  onBrowseProject?(): void;
  /// This Mac's name (the handshake's `machineName`).
  localName?: string;
  /// The folder a started chat moved to.
  movedTo?: string;
  onMove?(cwd: string): void;
  /// A turn runs: the folder holds still.
  busy?: boolean;
  /// A new chat's Computer menu ends with SSH… and cmux Cloud…, which open the host's
  /// connect flows (Lawrence 2026-10-06: "I cannot click on cmux Cloud SSH").
  onConnect?(kind: "ssh" | "cloud"): void;
}) {
  const computers = useMemo(
    () => availableComputers(summary, sessions, peers, localName),
    [summary, sessions, peers, localName],
  );
  const initialComputer = computerId(summary);
  const [selectedComputer, setSelectedComputer] = useState(initialComputer);
  useEffect(() => setSelectedComputer(initialComputer), [summary?.sessionId, initialComputer]);
  const folders = useMemo(() => {
    const known = availableFolders(summary, sessions, selectedComputer);
    if (selectedComputer !== "local" || !projectChoices) return known;
    const projects = projectChoices.map((project) => ({
      id: normalizeCwd(project.cwd)!,
      label: project.label,
      detail: project.cwd,
    }));
    const seen = new Set(projects.map((project) => project.id));
    return [...projects, ...known.filter((folder) => !seen.has(folder.id))];
  }, [summary, sessions, selectedComputer, projectChoices]);
  const summaryFolder = summary?.cwd && computerId(summary) === selectedComputer ? summary.cwd : undefined;
  // A chat in its private agent-home folder has no project yet: the row offers a folder instead.
  const currentFolder =
    started && movedTo
      ? movedTo
      : summaryFolder
        ? isAgentHome(summaryFolder)
          ? undefined
          : normalizeCwd(summaryFolder)
        : projectChoices
          ? undefined
          : folders[0]?.id;
  const currentComputer = computers.find((computer) => computer.id === selectedComputer) ?? computers[0];
  if (!currentComputer && !currentFolder && !projectChoices) return null;
  const readOnly = started || onProject === undefined;
  const moves = started && onMove !== undefined && !busy;
  const branch = summary?.branch;
  return (
    <div className="acpmux-composer-context" data-readonly={readOnly ? "true" : undefined}>
      <div className="acpmux-location-leading">
        {readOnly && !moves && !currentFolder ? null : !readOnly && selectedComputer === "local" && projectChoices ? (
          <FolderMenu
            label={t(CONTEXT_LABELS.folder)}
            menu="Location"
            folders={folders}
            current={currentFolder}
            onPick={(cwd) => onProject?.(cwd)}
            onBrowse={onBrowseProject}
          />
        ) : (
          <LocationPicker
            label={t(CONTEXT_LABELS.folder)}
            menu="Location"
            value={currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)}
            options={folders}
            selected={currentFolder}
            disabled={readOnly && !moves}
            icon={<FolderIcon />}
            allowPath
            onPick={(cwd) => {
              if (moves) {
                if (cwd !== currentFolder) onMove?.(cwd);
              } else if (!readOnly) onProject?.(cwd, selectedComputer === "local" ? undefined : selectedComputer);
            }}
          />
        )}
        <LocationPicker
          label={t(CONTEXT_LABELS.computer)}
          menu="Computer"
          value={currentComputer?.label ?? t(CONTEXT_LABELS.chooseComputer)}
          options={computers}
          selected={selectedComputer}
          disabled={readOnly && (started || !onConnect)}
          extras={
            !started && onConnect
              ? [
                  { id: "ssh", label: t(CONTEXT_LABELS.connectSSH), onSelect: () => onConnect("ssh") },
                  { id: "cloud", label: t(CONTEXT_LABELS.connectCloud), onSelect: () => onConnect("cloud") },
                ]
              : undefined
          }
          onPick={(id) => {
            if (!readOnly && id !== selectedComputer) {
              setSelectedComputer(id);
              const folder = availableFolders(summary, sessions, id)[0]?.id;
              if (folder) onProject?.(folder, id === "local" ? undefined : id);
            }
          }}
        />
      </div>
      {branch && <BranchPicker branch={branch} />}
    </div>
  );
}

function BranchPicker({ branch }: { branch: string }) {
  const [open, setOpen] = useState(false);
  const [control, anchor] = useCardAnchor();
  return (
    <span ref={control} className="acpmux-location-picker" title={branch}>
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-location-button" label={t("changes.scope.branch")}>
          <LocationFace icon={<BranchIcon />} value={branch} chevron />
        </MenuButton>
        <MenuPopup side="top" anchor={anchor} className="acpmux-menu acpmux-location-menu" align="end">
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
      className="acpmux-icon acpmux-location-icon"
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

function computerId(summary?: Summary): string {
  return summary?.hostKind === "cloud" && (summary.peer || summary.host) ? (summary.peer ?? summary.host)! : "local";
}

function availableComputers(
  summary: Summary | undefined,
  sessions: Session[],
  peers: string[],
  localName?: string,
): Location[] {
  const localLabel =
    localName || (summary?.hostKind === "local" && summary.host ? summary.host : t(CONTEXT_LABELS.local));
  const computers: Location[] = [{ id: "local", label: localLabel }];
  const seen = new Set<string>();
  for (const peer of peers) {
    if (seen.has(peer)) continue;
    seen.add(peer);
    computers.push({ id: peer, label: peer, detail: t(CONTEXT_LABELS.cloud) });
  }
  for (const session of sessions) {
    const peer = session.peer ?? (session.hostKind === "cloud" ? session.host : undefined);
    if (!peer || seen.has(peer)) continue;
    seen.add(peer);
    computers.push({ id: peer, label: session.host ?? peer, detail: t(CONTEXT_LABELS.cloud) });
  }
  const summaryPeer = summary?.hostKind === "cloud" ? (summary.peer ?? summary.host) : undefined;
  if (summaryPeer && !seen.has(summaryPeer)) {
    computers.push({
      id: summaryPeer,
      label: summary?.host ?? summaryPeer,
      detail: t(CONTEXT_LABELS.cloud),
    });
  }
  return computers;
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
/// wrapped) and, on a control that opens a menu, a chevron. One look for the whole row.
function LocationFace({ icon, value, chevron }: { icon?: React.ReactNode; value: string; chevron: boolean }) {
  return (
    <>
      {icon}
      <span className="acpmux-location-label">{value}</span>
      {chevron && <ChevronIcon />}
    </>
  );
}

function FolderIcon() {
  return (
    <svg
      className="acpmux-icon acpmux-location-icon"
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

/// The location menus open above the whole composer card (cx-yrgh). The row is the card's footer,
/// so a menu on its control's top side covered the prompt above the row. The anchor takes the
/// control's width and runs from the card's top edge down to the control's bottom, so `side="top"`
/// puts the menu's bottom at the card's top edge. With too little room above the card the folder
/// list scrolls (composerLocation.css caps it at the room the positioner reports); only when the
/// room below the row is larger does the positioner flip the menu under the row. Either way the
/// card stays uncovered. The box is read at each placement, so it follows the card as it grows.
function useCardAnchor() {
  const control = useRef<HTMLSpanElement>(null);
  const anchor = useMemo<UiVirtualAnchor>(
    () => ({
      getBoundingClientRect: () => cardEdgeRect(control.current),
      get contextElement() {
        return control.current ?? undefined;
      },
    }),
    [],
  );
  return [control, anchor] as const;
}

function cardEdgeRect(control: Element | null): DOMRect {
  const own = control?.getBoundingClientRect();
  const card = control?.closest(".acpmux-composer-box")?.getBoundingClientRect();
  const left = own?.left ?? 0;
  const right = own?.right ?? 0;
  const bottom = own?.bottom ?? 0;
  const top = Math.min(card?.top ?? bottom, own?.top ?? bottom);
  const rect = { x: left, y: top, left, top, right, bottom, width: right - left, height: bottom - top };
  return { ...rect, toJSON: () => rect } as DOMRect;
}

/// Automation opens a location menu by its stable name (`openPicker`: "Computer", "Location"),
/// as a click does: the focus leaves the prompt, then the menu opens. A label (a started chat)
/// registers nothing.
function useLocationOpener(name: string | undefined, open: () => void) {
  const latest = useRef(open);
  latest.current = open;
  useEffect(() => {
    if (!name) return;
    return registerPicker(name, () => {
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
      latest.current();
    });
  }, [name]);
}

/// The new chat's folder menu: the recent folders (the current one checked), then Choose folder…,
/// which asks the host for its folder panel from the click itself. Base UI owns the menu's roles,
/// focus, arrows, typeahead and Escape. The full path is the control's tooltip.
function FolderMenu({
  label,
  menu,
  folders,
  current,
  onPick,
  onBrowse,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  folders: Location[];
  current?: string;
  onPick(cwd: string): void;
  onBrowse?(): void;
}) {
  const [open, setOpen] = useState(false);
  const [control, anchor] = useCardAnchor();
  useLocationOpener(menu, () => setOpen(true));
  const value = current ? projectLabel(current) : t(CONTEXT_LABELS.chooseFolder);
  return (
    <span ref={control} className="acpmux-location-picker" title={current}>
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-location-button" label={label}>
          <LocationFace icon={<FolderIcon />} value={value} chevron />
        </MenuButton>
        <MenuPopup side="top" anchor={anchor} className="acpmux-menu acpmux-location-menu" align="start">
          {folders.length > 0 && (
            <>
              <div className="acpmux-location-folders">
                <MenuRadioGroup
                  value={current ?? ""}
                  onValueChange={(cwd) => {
                    setOpen(false);
                    if (cwd !== current) onPick(cwd);
                  }}
                >
                  {folders.map((folder) => (
                    <MenuRadioItem key={folder.id} value={folder.id} className="acpmux-menu-item">
                      <ProjectBadge project={{ cwd: folder.id, label: folder.label }} />
                      <span className="acpmux-menu-text" title={folder.id}>
                        <span className="acpmux-menu-label">{folder.label}</span>
                        <span className="acpmux-menu-description">{folder.detail ?? folder.id}</span>
                      </span>
                    </MenuRadioItem>
                  ))}
                </MenuRadioGroup>
              </div>
              {onBrowse && <MenuSeparator />}
            </>
          )}
          {onBrowse && (
            <MenuItem
              className="acpmux-menu-item acpmux-location-choose"
              onSelect={() => {
                setOpen(false);
                onBrowse();
              }}
            >
              <span className="ui-menu-check" aria-hidden="true" />
              <span className="acpmux-menu-label">{t(CONTEXT_LABELS.chooseFolderMenu)}</span>
            </MenuItem>
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// A location menu (shared components, plans/cmux-next/a11y-foundation.md): a menu button over a
/// radio menu of the options; Base UI owns the roles, focus, arrows, typeahead and Escape. The
/// folder menu (`allowPath`) is a popover with a field: typing filters the folders, and a typed
/// absolute or `~/` path is offered too.
function LocationPicker({
  label,
  menu,
  value,
  options,
  selected,
  disabled,
  icon,
  allowPath = false,
  extras,
  onPick,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  value: string;
  options: Location[];
  selected?: string;
  disabled: boolean;
  icon?: React.ReactNode;
  allowPath?: boolean;
  /// Rows after the choices that run something instead of picking (the connect flows).
  extras?: { id: string; label: string; onSelect(): void }[];
  onPick(id: string): void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [control, anchor] = useCardAnchor();
  const press = usePopoverTrigger(open, setOpen);
  useLocationOpener(disabled ? undefined : menu, () => setOpen(true));
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return options.filter((option) =>
      words.every((word) => (option.label + " " + (option.detail ?? "")).toLowerCase().includes(word)),
    );
  }, [options, query]);
  if (disabled)
    return (
      <span className="acpmux-location-picker">
        <span
          className="acpmux-location-readonly"
          aria-label={label + ": " + value}
          title={label + ": " + (allowPath && selected ? selected : value)}
        >
          <LocationFace icon={icon} value={value} chevron={false} />
        </span>
      </span>
    );
  const pick = (id: string) => {
    onPick(id);
    setOpen(false);
    setQuery("");
  };
  const button = <LocationFace icon={icon} value={value} chevron />;
  if (!allowPath)
    return (
      <span ref={control} className="acpmux-location-picker">
        <Menu open={open} onOpenChange={setOpen}>
          <MenuButton className="acpmux-location-button" label={label}>
            {button}
          </MenuButton>
          <MenuPopup side="top" anchor={anchor} className="acpmux-menu acpmux-location-menu" align="start">
            <MenuRadioGroup value={selected ?? ""} onValueChange={pick}>
              {options.map((option) => (
                <MenuRadioItem key={option.id} value={option.id} className="acpmux-menu-item">
                  <span className="acpmux-menu-text">
                    <span className="acpmux-menu-label">{option.label}</span>
                    {option.detail && <span className="acpmux-menu-description">{option.detail}</span>}
                  </span>
                </MenuRadioItem>
              ))}
            </MenuRadioGroup>
            {extras && extras.length > 0 && <MenuSeparator />}
            {extras?.map((extra) => (
              <MenuItem
                key={extra.id}
                className="acpmux-menu-item"
                onSelect={() => {
                  setOpen(false);
                  extra.onSelect();
                }}
              >
                {extra.label}
              </MenuItem>
            ))}
          </MenuPopup>
        </Menu>
      </span>
    );
  // The folder field suggests folder paths; a typed path that names none is offered as typed.
  const typedPath = /^(?:\/|~\/)/.test(query.trim()) ? query.trim() : undefined;
  const suggestions = shown.map((option) => option.id);
  if (typedPath && !suggestions.includes(typedPath)) suggestions.push(typedPath);
  return (
    <span ref={control} className="acpmux-location-picker" title={selected}>
      <button
        type="button"
        className="acpmux-location-button"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {button}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setQuery("");
        }}
        anchor={open ? anchor : null}
        label={label}
        className="acpmux-menu acpmux-location-menu"
        side="top"
      >
        <Combobox
          suggestions={suggestions}
          onQuery={setQuery}
          onSubmit={(path) => (path ? pick(path) : setOpen(false))}
          onCancel={() => setOpen(false)}
          label={label}
          placeholder={value}
          inputClassName="acpmux-location-search"
          itemClassName="acpmux-menu-item"
          renderItem={(path) => {
            const folder = options.find((option) => option.id === path);
            return (
              <span className="acpmux-menu-text">
                <span className="acpmux-menu-label">{folder?.label ?? path}</span>
                {folder?.detail && <span className="acpmux-menu-description">{folder.detail}</span>}
              </span>
            );
          }}
          inline
        />
      </Popover>
    </span>
  );
}
