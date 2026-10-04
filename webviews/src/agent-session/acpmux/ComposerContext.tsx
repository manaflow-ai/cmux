import React, { useEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { projectLabel } from "./sessionList";
import { t } from "./i18n";

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
}: {
  summary?: Summary;
  sessions?: Session[];
  peers?: string[];
  started?: boolean;
  onProject?(cwd: string, peer?: string): void;
}) {
  const computers = useMemo(
    () => availableComputers(summary, sessions, peers),
    [summary, sessions, peers],
  );
  const initialComputer = computerId(summary);
  const [selectedComputer, setSelectedComputer] = useState(initialComputer);
  useEffect(() => setSelectedComputer(initialComputer), [summary?.sessionId, initialComputer]);
  const folders = useMemo(
    () => availableFolders(summary, sessions, selectedComputer),
    [summary, sessions, selectedComputer],
  );
  const currentFolder =
    summary?.cwd && computerId(summary) === selectedComputer ? summary.cwd : folders[0]?.id;
  const currentComputer =
    computers.find((computer) => computer.id === selectedComputer) ?? computers[0];
  if (!currentComputer && !currentFolder) return null;
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
      <LocationPicker
        label={t(CONTEXT_LABELS.folder)}
        value={currentFolder ? projectLabel(currentFolder) : t(CONTEXT_LABELS.chooseFolder)}
        options={folders}
        selected={currentFolder}
        disabled={readOnly}
        allowPath
        onPick={(cwd) => {
          if (!readOnly)
            onProject?.(cwd, selectedComputer === "local" ? undefined : selectedComputer);
        }}
      />
    </div>
  );
}

function computerId(summary?: Summary): string {
  return summary?.hostKind === "cloud" && (summary.peer || summary.host)
    ? (summary.peer ?? summary.host)!
    : "local";
}

function availableComputers(
  summary: Summary | undefined,
  sessions: Session[],
  peers: string[],
): Location[] {
  const localLabel =
    summary?.hostKind === "local" && summary.host ? summary.host : t(CONTEXT_LABELS.local);
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

function availableFolders(
  summary: Summary | undefined,
  sessions: Session[],
  computer: string,
): Location[] {
  const seen = new Set<string>();
  const folders: Location[] = [];
  const add = (cwd?: string) => {
    const id = cwd?.replace(/\/+$/, "");
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
  const [active, setActive] = useState(0);
  const root = useRef<HTMLSpanElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return options.filter((option) =>
      words.every((word) =>
        (option.label + " " + (option.detail ?? "")).toLowerCase().includes(word),
      ),
    );
  }, [options, query]);
  const typedPath = allowPath && /^(?:\/|~\/)/.test(query.trim()) ? query.trim() : undefined;
  const close = () => {
    setOpen(false);
    setQuery("");
    trigger.current?.focus();
  };
  const show = () => {
    setQuery("");
    setActive(
      Math.max(
        0,
        options.findIndex((option) => option.id === selected),
      ),
    );
    setOpen(true);
  };
  useEffect(() => {
    if (!open) return;
    if (allowPath) search.current?.focus();
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", away);
    return () => document.removeEventListener("pointerdown", away);
  }, [allowPath, open]);
  const keyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (shown.length > 0)
        setActive(
          (current) =>
            (current + (event.key === "ArrowDown" ? 1 : -1) + shown.length) % shown.length,
        );
    } else if (event.key === "Enter") {
      event.preventDefault();
      const option = shown[active];
      if (option) onPick(option.id);
      else if (typedPath) onPick(typedPath);
      close();
    }
  };
  return (
    <span ref={root} className="acpmux-location-picker">
      {disabled ? (
        <span
          className="acpmux-location-readonly"
          aria-label={label + ": " + value}
          title={label + ": " + value}
        >
          {value}
        </span>
      ) : (
        <>
          <button
            ref={trigger}
            type="button"
            className="acpmux-location-button"
            aria-label={label}
            aria-haspopup="listbox"
            aria-expanded={open}
            onClick={() => (open ? close() : show())}
          >
            <span>{value}</span>
            <span aria-hidden="true">⌄</span>
          </button>
          {open && (
            <div className="acpmux-menu acpmux-menu-end acpmux-location-menu">
              {allowPath && (
                <input
                  ref={search}
                  className="acpmux-location-search"
                  type="text"
                  aria-label={label}
                  placeholder={value}
                  value={query}
                  onChange={(event) => {
                    setQuery(event.target.value);
                    setActive(0);
                  }}
                  onKeyDown={keyDown}
                />
              )}
              {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
              <div role="listbox" aria-label={label}>
                {shown.map((option, index) => (
                  <button
                    type="button"
                    key={option.id}
                    className="acpmux-menu-item"
                    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                    role="option"
                    aria-selected={option.id === selected}
                    data-active={index === active ? "true" : undefined}
                    onClick={() => {
                      onPick(option.id);
                      setOpen(false);
                      setQuery("");
                    }}
                  >
                    <span className="acpmux-menu-text">
                      <span className="acpmux-menu-label">{option.label}</span>
                      {option.detail && (
                        <span className="acpmux-menu-description">{option.detail}</span>
                      )}
                    </span>
                  </button>
                ))}
                {shown.length === 0 && typedPath && (
                  <button
                    type="button"
                    className="acpmux-menu-item acpmux-menu-active"
                    onClick={() => {
                      onPick(typedPath);
                      close();
                    }}
                  >
                    <span className="acpmux-menu-label">{typedPath}</span>
                  </button>
                )}
              </div>
            </div>
          )}
        </>
      )}
    </span>
  );
}
