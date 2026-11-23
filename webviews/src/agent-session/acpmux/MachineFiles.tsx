import React, { useEffect, useId, useRef, useState } from "react";
import { useT } from "./i18n";
import { machineFolder, type MachineFilesList, type MachineFolder } from "./machineFilesModel";
import { useScrollEdges } from "../../ui/scrollEdges";
import { focusRoute } from "../../ui/focusRoute";

type State =
  | { kind: "loading"; shown?: MachineFolder }
  | { kind: "shown"; folder: MachineFolder }
  | { kind: "failed"; message: string; path?: string };

/// Browse files on this machine: the files of a chat on another machine, read by that machine's own
/// daemon (``machineFolder``), drawn where Search files draws. A folder row goes into it, Up goes to its
/// parent, a file row opens the file beside the chat (the host's `file.open`, which reads that machine's
/// file). Arrows move the highlight, Enter opens, Backspace goes up, Escape closes.
export function MachineFiles({
  list,
  start,
  onOpenFile,
  onClose,
}: {
  list: MachineFilesList;
  /// The chat's folder on that machine; none starts where the machine says.
  start?: string;
  onOpenFile(path: string): void;
  onClose(): void;
}) {
  const t = useT();
  const [state, setState] = useState<State>({ kind: "loading" });
  const [active, setActive] = useState(0);
  const root = useRef<HTMLDialogElement>(null);
  const listId = useId();
  const listEdges = useScrollEdges();
  // Only the newest listing lands; one that answers late after another folder was asked is dropped.
  const generation = useRef(0);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const go = (path: string | undefined) => {
    const ask = ++generation.current;
    setState((current) => ({ kind: "loading", ...(current.kind === "shown" ? { shown: current.folder } : {}) }));
    list(path).then(
      (listing) => {
        if (ask !== generation.current) return;
        try {
          setState({ kind: "shown", folder: machineFolder(listing) });
          setActive(0);
        } catch (error) {
          setState({ kind: "failed", message: (error as Error).message, ...(path ? { path } : {}) });
        }
      },
      () => {
        if (ask === generation.current)
          setState({ kind: "failed", message: t("machineFiles.failed"), ...(path ? { path } : {}) });
      },
    );
  };

  useEffect(() => {
    go(start);
    focusRoute(root.current, "person", "Browse files on this machine opened: its list");
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) onCloseRef.current();
    };
    document.addEventListener("pointerdown", away);
    const requests = generation;
    return () => {
      document.removeEventListener("pointerdown", away);
      requests.current++;
    };
    // One listing on open; later ones follow the person's clicks.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const folder = state.kind === "shown" ? state.folder : state.kind === "loading" ? state.shown : undefined;
  const entries = folder?.entries ?? [];
  const selected = Math.min(active, Math.max(entries.length - 1, 0));
  const pick = (index: number) => {
    const entry = entries[index];
    if (!entry) return;
    if (entry.folder) go(entry.path);
    else onOpenFile(entry.path);
  };
  const up = () => {
    if (folder?.parent) go(folder.parent);
  };

  const keyDown = (event: React.KeyboardEvent) => {
    if (event.nativeEvent.isComposing) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (entries.length > 0)
        setActive((selected + (event.key === "ArrowDown" ? 1 : -1) + entries.length) % entries.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      pick(selected);
    } else if (event.key === "Backspace") {
      event.preventDefault();
      up();
    }
  };

  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex
    <dialog
      ref={root}
      open
      tabIndex={-1}
      className="acpmux-file-search acpmux-machine-files"
      aria-label={t("machineFiles.title")}
      onKeyDown={keyDown}
    >
      <header className="acpmux-machine-files-bar">
        <button
          type="button"
          className="acpmux-machine-files-up"
          disabled={!folder?.parent}
          onClick={up}
          aria-label={t("machineFiles.up")}
        >
          ↑
        </button>
        <span className="acpmux-machine-files-path" title={folder?.path}>
          {folder?.path ?? t("machineFiles.title")}
        </span>
      </header>
      <div
        ref={listEdges}
        id={listId}
        className="ui-scroll-edge-fade"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="listbox"
        aria-label={folder?.path ?? t("machineFiles.title")}
        aria-busy={state.kind === "loading"}
      >
        {entries.map((entry, index) => (
          <div
            key={entry.path}
            id={`${listId}-${index}`}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="option"
            tabIndex={-1}
            aria-selected={index === selected}
            data-kind={entry.folder ? "folder" : "file"}
            className={`acpmux-file-result${index === selected ? " acpmux-menu-active" : ""}`}
            onPointerMove={() => setActive(index)}
            onMouseDown={(event) => {
              event.preventDefault();
              pick(index);
            }}
          >
            <span className="acpmux-file-name">
              {entry.name}
              {entry.folder ? "/" : ""}
            </span>
          </div>
        ))}
      </div>
      {state.kind === "failed" && (
        <output className="acpmux-file-note">
          {state.message}{" "}
          <button type="button" className="acpmux-machine-files-retry" onClick={() => go(state.path)}>
            {t("machineFiles.retry")}
          </button>
        </output>
      )}
      {state.kind === "loading" && !folder && (
        <output className="acpmux-file-loading-note">{t("machineFiles.loading")}</output>
      )}
      {state.kind === "shown" && entries.length === 0 && (
        <output className="acpmux-file-note">{t("machineFiles.empty")}</output>
      )}
      {state.kind === "shown" && state.folder.truncated && (
        <output className="acpmux-file-note">{t("machineFiles.more", { count: entries.length })}</output>
      )}
    </dialog>
  );
}
