import React, { useEffect, useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../ui/Menu";
import { Popover } from "../../ui/Popover";
import type { AcpmuxSnapshot } from "./model";
import { ChevronIcon } from "./ComposerPickers";
import { ProjectChooser, type Project } from "./ProjectChooser";
import { projectLabel } from "./sessionList";
import { translate as t } from "./i18n";

export const CONTEXT_LABELS = {
  computer: "composer.computer",
  folder: "composer.folder",
  local: "composer.thisMac",
  chooseComputer: "composer.chooseComputer",
  chooseFolder: "composer.chooseFolder",
  cloud: "composer.cloud",
} as const;

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
type Session = AcpmuxSnapshot["sessions"][number];
type Location = { id: string; label: string; detail?: string };

/// The small location row above the composer. New chats can choose a local or Cloud
/// computer and one of its known folders; once the first turn starts both are labels.
export function ComposerContext({
  summary,
  sessions = [],
  peers = [],
  started = false,
  onProject,
  projectChoices,
  onBrowseProject,
}: {
  summary?: Summary;
  sessions?: Session[];
  peers?: string[];
  started?: boolean;
  onProject?(cwd: string, peer?: string): void;
  projectChoices?: Project[];
  onBrowseProject?(): void;
}) {
  const computers = useMemo(() => availableComputers(summary, sessions, peers), [summary, sessions, peers]);
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
  const currentFolder =
    summary?.cwd && computerId(summary) === selectedComputer
      ? normalizeCwd(summary.cwd)
      : projectChoices
        ? undefined
        : folders[0]?.id;
  const currentComputer = computers.find((computer) => computer.id === selectedComputer) ?? computers[0];
  if (!currentComputer && !currentFolder && !projectChoices) return null;
  const readOnly = started || onProject === undefined;
  return (
    <div className="acpmux-composer-context" data-readonly={readOnly ? "true" : undefined}>
      <LocationPicker
        label={t(CONTEXT_LABELS.computer)}
        value={currentComputer?.label ?? t(CONTEXT_LABELS.chooseComputer)}
        options={computers}
        selected={selectedComputer}
        disabled={readOnly}
        onPick={(id) => {
          if (!readOnly && id !== selectedComputer) {
            setSelectedComputer(id);
            const folder = availableFolders(summary, sessions, id)[0]?.id;
            if (folder) onProject?.(folder, id === "local" ? undefined : id);
          }
        }}
      />
      <span className="acpmux-context-divider" aria-hidden="true">
        ·
      </span>
      {!readOnly && selectedComputer === "local" && projectChoices ? (
        <ProjectChooser
          projects={folders.map((folder) => ({ cwd: folder.id, label: folder.label }))}
          current={currentFolder}
          currentLabel={currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)}
          icon={null}
          onPick={(cwd) => onProject?.(cwd)}
          onBrowse={onBrowseProject}
        />
      ) : (
        <LocationPicker
          label={t(CONTEXT_LABELS.folder)}
          value={currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)}
          options={folders}
          selected={currentFolder}
          disabled={readOnly}
          allowPath
          onPick={(cwd) => {
            if (!readOnly) onProject?.(cwd, selectedComputer === "local" ? undefined : selectedComputer);
          }}
        />
      )}
    </div>
  );
}

function computerId(summary?: Summary): string {
  return summary?.hostKind === "cloud" && (summary.peer || summary.host) ? (summary.peer ?? summary.host)! : "local";
}

function availableComputers(summary: Summary | undefined, sessions: Session[], peers: string[]): Location[] {
  const localLabel = summary?.hostKind === "local" && summary.host ? summary.host : t(CONTEXT_LABELS.local);
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
    if (!id || seen.has(id)) return;
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

/// A location menu (shared components, plans/cmux-next/a11y-foundation.md): a menu button over a
/// radio menu of the options; Base UI owns the roles, focus, arrows, typeahead and Escape. The
/// folder menu (`allowPath`) is a popover with a field: typing filters the folders, and a typed
/// absolute or `~/` path is offered too.
function LocationPicker({
  label,
  value,
  options,
  selected,
  disabled,
  allowPath = false,
  onPick,
}: {
  label: string;
  value: string;
  options: Location[];
  selected?: string;
  disabled: boolean;
  allowPath?: boolean;
  onPick(id: string): void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const trigger = useRef<HTMLButtonElement>(null);
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return options.filter((option) =>
      words.every((word) => (option.label + " " + (option.detail ?? "")).toLowerCase().includes(word)),
    );
  }, [options, query]);
  if (disabled)
    return (
      <span className="acpmux-location-picker">
        <span className="acpmux-location-readonly" aria-label={label + ": " + value} title={label + ": " + value}>
          {value}
        </span>
      </span>
    );
  const pick = (id: string) => {
    onPick(id);
    setOpen(false);
    setQuery("");
  };
  const button = (
    <>
      <span>{value}</span>
      <ChevronIcon />
    </>
  );
  if (!allowPath)
    return (
      <span className="acpmux-location-picker">
        <Menu open={open} onOpenChange={setOpen}>
          <MenuButton className="acpmux-location-button" label={label}>
            {button}
          </MenuButton>
          <MenuPopup className="acpmux-menu acpmux-location-menu" align="start">
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
          </MenuPopup>
        </Menu>
      </span>
    );
  // The folder field suggests folder paths; a typed path that names none is offered as typed.
  const typedPath = /^(?:\/|~\/)/.test(query.trim()) ? query.trim() : undefined;
  const suggestions = shown.map((option) => option.id);
  if (typedPath && !suggestions.includes(typedPath)) suggestions.push(typedPath);
  return (
    <span className="acpmux-location-picker">
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        {button}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setQuery("");
        }}
        anchor={open ? trigger.current : null}
        label={label}
        className="acpmux-menu acpmux-location-menu"
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
