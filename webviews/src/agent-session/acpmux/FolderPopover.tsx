import React, { useMemo, useRef, useState } from "react";
import { Combobox } from "../../ui/Combobox";
import { Popover } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { AddProjectDialog } from "./AddProjectPanel";
import { translate as t } from "./i18n";
import { useLocationOpener, useLocationPopover } from "./locationPopover";
import { ProjectBadge } from "./ProjectBadge";
import { projectSuffixes } from "./projectSuffix";

/// A folder the popover offers: its path (`id`) and name.
export type FolderChoice = { id: string; label: string };

/// The new chat's folder popover (hq#1957 composer location strip): a search field over the folders,
/// each named by its project and, only when another shares that name, a short suffix that tells it
/// apart (projectSuffix.ts: the lane, "cmux · cg-lane-adopt"); the full path is the row's tooltip.
/// The current folder is checked. After the folders: New Worktree, Add project and Choose folder…,
/// each only where the host offers it. The shared Combobox keeps the keyboard in the field: typing
/// filters by name, suffix and path; ↑/↓ move through the folders and the actions; Return picks;
/// Escape closes back to the strip. A typed absolute or `~/` path is offered as typed.
export function FolderPopover({
  label,
  menu,
  face,
  folders,
  current,
  onPick,
  onBrowse,
  onNewWorktree,
  localName,
  peers,
}: {
  label: string;
  /// The name automation opens it by (`openPicker`).
  menu: string;
  /// The strip control's face (icon, name, chevron).
  face: React.ReactNode;
  folders: FolderChoice[];
  current?: string;
  onPick(cwd: string): void;
  /// The host's folder panel: Add project's Browse and Choose folder….
  onBrowse?(): void;
  /// New Worktree of the current folder.
  onNewWorktree?(): void;
  localName?: string;
  peers?: string[];
}) {
  const [adding, setAdding] = useState(false);
  const [query, setQuery] = useState("");
  const highlighted = useRef<string | undefined>(undefined);
  const trigger = useRef<HTMLButtonElement>(null);
  // Escape (not a blur) closes back to the strip's control.
  const escaped = useRef(false);
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const press = usePopoverTrigger(open, (next) => {
    setOpen(next);
    if (!next) setQuery("");
  });
  useLocationOpener(menu, () => setOpen(true));
  const suffixes = useMemo(
    () => projectSuffixes(folders.map((folder) => ({ cwd: folder.id, label: folder.label }))),
    [folders],
  );
  const shown = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return folders.filter((folder) => {
      const text = `${folder.label} ${suffixes.get(folder.id) ?? ""} ${folder.id}`.toLowerCase();
      return words.every((word) => text.includes(word));
    });
  }, [folders, suffixes, query]);
  const typed = query.trim();
  const typedPath = /^(?:\/|~\/)/.test(typed) && !shown.some((folder) => folder.id === typed) ? typed : undefined;
  // The actions follow the folders in the same list, so the arrows reach them from the field.
  const actions: { value: string; text: string; run(): void }[] = [
    ...(onNewWorktree ? [{ value: ACTION + "worktree", text: t("worktree.new"), run: onNewWorktree }] : []),
    ...(onBrowse
      ? [
          { value: ACTION + "add", text: t("project.add"), run: () => setAdding(true) },
          { value: ACTION + "browse", text: t("composer.chooseFolderMenu"), run: onBrowse },
        ]
      : []),
  ];
  const suggestions = [
    ...shown.map((folder) => folder.id),
    ...(typedPath ? [typedPath] : []),
    ...actions.map((action) => action.value),
  ];
  const close = () => {
    setOpen(false);
    setQuery("");
    if (escaped.current) trigger.current?.focus();
    escaped.current = false;
  };
  const submit = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    close();
    if (action) action.run();
    else if (value && value !== current && (shown.some((folder) => folder.id === value) || value === typedPath))
      onPick(value);
  };
  const row = (value: string) => {
    const action = actions.find((candidate) => candidate.value === value);
    if (action)
      return (
        <span
          className="acpmux-location-action"
          data-first={action === actions[0] ? "" : undefined}
          data-choose={action.value === ACTION + "browse" ? "" : undefined}
        >
          <span className="acpmux-menu-label">{action.text}</span>
        </span>
      );
    const folder = folders.find((candidate) => candidate.id === value);
    if (!folder)
      return (
        <span className="acpmux-location-row">
          <span className="acpmux-menu-label">{t("project.usePath", { path: value })}</span>
        </span>
      );
    const suffix = suffixes.get(folder.id);
    return (
      // tooltip-allow: the row shows the folder's name; the tooltip is its full path
      <span className="acpmux-location-row" title={folder.id} data-current={folder.id === current ? "" : undefined}>
        <ProjectBadge project={{ cwd: folder.id, label: folder.label }} />
        <span className="acpmux-menu-text acpmux-location-name">
          <span className="acpmux-menu-label">{folder.label}</span>
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
        <span className="acpmux-location-check" aria-hidden="true">
          {folder.id === current && <CheckIcon />}
        </span>
      </span>
    );
  };

  return (
    <span ref={control} className="acpmux-location-picker">
      <button
        ref={trigger}
        type="button"
        className="acpmux-location-button ui-ghost ui-ghost-sm"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
      >
        {face}
      </button>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) setQuery("");
        }}
        anchor={open ? anchor : null}
        label={label}
        className="acpmux-menu acpmux-location-menu acpmux-folder-popover"
        side={side}
        flip={false}
        finalFocus={false}
      >
        <Combobox
          suggestions={suggestions}
          onQuery={setQuery}
          onSubmit={submit}
          onCancel={close}
          onHighlight={(value) => {
            highlighted.current = value;
          }}
          // Tab completes a folder's path into the field, never an action's.
          onCommand={(event) => {
            if (event.key === "Escape") escaped.current = true;
            if (event.key === "Tab" && highlighted.current?.startsWith(ACTION)) event.preventDefault();
          }}
          label={t("project.search")}
          placeholder={t("project.search")}
          inputClassName="acpmux-location-search"
          listClassName="acpmux-location-folders"
          itemClassName="acpmux-menu-item"
          renderItem={row}
          autoHighlight
          inline
        />
        {shown.length === 0 && !typedPath && (
          <div className="acpmux-location-empty">{t(typed ? "project.none" : "project.noneYet")}</div>
        )}
      </Popover>
      <AddProjectDialog
        open={adding}
        localName={localName}
        peers={peers}
        onBrowse={onBrowse}
        onClose={() => setAdding(false)}
        onPick={(cwd) => {
          setAdding(false);
          onPick(cwd);
        }}
      />
    </span>
  );
}

/// An action row's value: never a path.
const ACTION = "\u0000action:";

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
