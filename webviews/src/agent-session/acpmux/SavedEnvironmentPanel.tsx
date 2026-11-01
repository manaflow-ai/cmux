import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";
import { browseFailureMessage } from "./BrowseFailure";
import { ChevronIcon } from "./ComposerPickers";
import { BROWSE_BUSY, type BrowseRequest, type BrowseResult } from "./AddProjectPanel";
import {
  SAVED_ENVIRONMENT_NAME_LIMIT,
  savedEnvironmentReady,
  savedEnvironmentToSave,
  type SavedEnvironment,
  type SavedEnvironmentDraft,
} from "./environments";
import { FolderPopover, type FolderChoice } from "./FolderPopover";
import { useT } from "./i18n";
import { projectLabel } from "./sessionList";
import "./savedEnvironments.css";

const KINDS: readonly SavedEnvironmentDraft["kind"][] = ["local", "ssh"];

export type SavedEnvironmentPanelProps = {
  /// The environment to edit; a new one when unset.
  environment?: SavedEnvironment;
  /// A new one's start: where the page's chat would start now.
  initial?: Pick<SavedEnvironmentDraft, "kind" | "folder">;
  /// This computer's folders (the page's projects), and the host's folder panel (Choose folder…).
  folders: FolderChoice[];
  onBrowse?(request?: BrowseRequest): Promise<BrowseResult>;
  /// The SSH machines (acpmux's `ssh://` peers) and each one's folders, from its chats.
  machines: string[];
  machineFolders(machine: string): FolderChoice[];
  /// The host's SSH… connect flow, for a machine the list does not have yet.
  onConnectSSH?(): void;
  /// Saves through the host; rejects with its reason, which the panel shows.
  onSave(environment: SavedEnvironmentDraft): Promise<void>;
  onRemove?(environment: SavedEnvironment): void;
  onClose(): void;
};

/// Create environment and Edit environment on the New Tab page (preview), inline under the
/// composer, never a modal: a name, This computer or SSH, the machine, its folder and, on this
/// computer, Use worktree. Escape cancels; ⌘↵ saves.
export function SavedEnvironmentPanel({
  environment,
  initial,
  folders,
  onBrowse,
  machines,
  machineFolders,
  onConnectSSH,
  onSave,
  onRemove,
  onClose,
}: SavedEnvironmentPanelProps) {
  const t = useT();
  const id = useId();
  const [draft, setDraft] = useState<SavedEnvironmentDraft>(
    () =>
      environment ?? {
        name: "",
        kind: initial?.kind ?? "local",
        ...(initial?.folder ? { folder: initial.folder } : {}),
      },
  );
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const [browsing, setBrowsing] = useState(false);
  const [browseFailed, setBrowseFailed] = useState(false);
  const name = useRef<HTMLInputElement>(null);
  const browseRequest = useRef(0);
  const browsePending = useRef(false);
  useEffect(() => {
    name.current?.focus();
    return () => {
      browseRequest.current += 1;
    };
  }, []);
  const ready = savedEnvironmentReady(draft) && !saving && !browsing;
  const update = (change: Partial<SavedEnvironmentDraft>) => {
    if (Object.prototype.hasOwnProperty.call(change, "folder")) {
      browseRequest.current += 1;
      setBrowsing(false);
      setBrowseFailed(false);
      setError(undefined);
    }
    setDraft((current) => ({ ...current, ...change }));
  };
  const save = () => {
    if (!ready) return;
    setSaving(true);
    setError(undefined);
    setBrowseFailed(false);
    void onSave(savedEnvironmentToSave(draft))
      .catch((failure: unknown) =>
        setError(
          t("environment.saveFailed", {
            reason: failure instanceof Error ? failure.message : String(failure),
          }),
        ),
      )
      .finally(() => setSaving(false));
  };
  const browse = (request?: BrowseRequest) => {
    if (!onBrowse) return Promise.resolve(undefined);
    if (browsePending.current) return Promise.resolve(BROWSE_BUSY);
    const id = ++browseRequest.current;
    browsePending.current = true;
    setBrowsing(true);
    setBrowseFailed(false);
    setError(undefined);
    return Promise.resolve()
      .then(() => onBrowse(request))
      .then((folder) => {
        if (browseRequest.current !== id) return undefined;
        if (typeof folder === "string" && folder.length > 0 && !request?.deferPick) {
          setDraft((current) => ({ ...current, folder }));
          setBrowseFailed(false);
          setError(undefined);
        }
        return folder;
      })
      .catch((failure: unknown) => {
        if (browseRequest.current !== id) return undefined;
        if (request?.deferPick) throw failure;
        setBrowseFailed(true);
        setError(browseFailureMessage(failure));
        return undefined;
      })
      .finally(() => {
        browsePending.current = false;
        if (browseRequest.current === id) setBrowsing(false);
      });
  };
  const command = (event: KeyboardEvent<HTMLDivElement>) => {
    // A menu or folder popover the panel opened draws elsewhere on the page and keeps its own keys.
    if (!event.currentTarget.contains(event.target as Node)) return;
    if (event.key === "Escape" && !event.defaultPrevented) {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
      save();
    }
  };
  const ssh = draft.kind === "ssh";
  const folderChoices = ssh ? (draft.host ? machineFolders(draft.host) : []) : folders;
  const title = environment ? t("environment.edit") : t("environment.new");
  return (
    <KeyboardScope handleKeyDown={command}>
      <section className="ui-glass acpmux-env-panel" aria-label={title}>
        <div className="acpmux-env-heading">{title}</div>
        <label className="acpmux-env-field" htmlFor={`${id}-name`}>
          <span className="acpmux-env-label">{t("environment.name")}</span>
          <input
            id={`${id}-name`}
            ref={name}
            aria-label={t("environment.name")}
            className="acpmux-env-input"
            value={draft.name}
            maxLength={SAVED_ENVIRONMENT_NAME_LIMIT}
            spellCheck={false}
            autoComplete="off"
            onChange={(event) => update({ name: event.target.value })}
          />
        </label>
        <div className="acpmux-env-tabs">
          {KINDS.map((kind) => (
            <button
              key={kind}
              type="button"
              className="acpmux-env-tab"
              aria-pressed={draft.kind === kind}
              onClick={() => {
                // Another machine's folders are its own: a switch starts with none.
                if (kind !== draft.kind) {
                  browseRequest.current += 1;
                  setBrowsing(false);
                  setBrowseFailed(false);
                  setError(undefined);
                  setDraft(({ id: kept, name: named }) => ({
                    ...(kept ? { id: kept } : {}),
                    name: named,
                    kind,
                  }));
                }
              }}
            >
              {kind === "local" ? t("composer.envLocal") : t("composer.envSSH")}
            </button>
          ))}
        </div>
        {ssh && (
          <div className="acpmux-env-field">
            <span className="acpmux-env-label">{t("environment.host")}</span>
            <Menu>
              <MenuButton className="acpmux-env-select" label={t("environment.host")} fieldTrigger>
                <span className="acpmux-env-select-text" data-placeholder={draft.host ? undefined : ""}>
                  {draft.host ?? t("environment.chooseHost")}
                </span>
                <ChevronIcon />
              </MenuButton>
              <MenuPopup className="acpmux-menu acpmux-location-menu acpmux-env-host-menu" align="start" matchTrigger>
                {machines.length > 0 && (
                  <MenuRadioGroup
                    value={draft.host ?? ""}
                    onValueChange={(host) => {
                      if (host !== draft.host) setDraft(({ folder: _folder, ...rest }) => ({ ...rest, host }));
                    }}
                  >
                    {machines.map((machine) => (
                      <MenuRadioItem key={machine} value={machine} className="acpmux-menu-item">
                        <span className="acpmux-menu-label">{machine}</span>
                      </MenuRadioItem>
                    ))}
                  </MenuRadioGroup>
                )}
                {machines.length > 0 && onConnectSSH && <MenuSeparator />}
                {onConnectSSH && (
                  <MenuItem className="acpmux-menu-item" onSelect={onConnectSSH}>
                    {t("environment.connect")}
                  </MenuItem>
                )}
              </MenuPopup>
            </Menu>
          </div>
        )}
        {(!ssh || draft.host) && (
          <div className="acpmux-env-field">
            <span className="acpmux-env-label">{t("composer.folder")}</span>
            <FolderPopover
              label={t("composer.folder")}
              menu="EnvironmentFolder"
              face={
                // tooltip-allow: the face shows only the folder's name; the tooltip is its whole path
                <span className="acpmux-env-select" title={draft.folder}>
                  <span className="acpmux-env-select-text" data-placeholder={draft.folder ? undefined : ""}>
                    {draft.folder ? projectLabel(draft.folder) : t("composer.chooseFolder")}
                  </span>
                  <ChevronIcon />
                </span>
              }
              folders={folderChoices}
              {...(draft.folder ? { current: draft.folder } : {})}
              onPick={(folder) => update({ folder })}
              {...(!ssh && onBrowse
                ? {
                    onBrowse: browse,
                  }
                : {})}
            />
          </div>
        )}
        {!ssh && draft.folder && (
          <label className="acpmux-env-check">
            <input
              type="checkbox"
              aria-label={t("environment.useWorktree")}
              checked={draft.worktree === true}
              onChange={(event) => update({ worktree: event.target.checked })}
            />
            <span>{t("environment.useWorktree")}</span>
          </label>
        )}
        <div className="acpmux-env-footer">
          <output className="acpmux-env-error" role={error ? "alert" : undefined}>
            {error}
          </output>
          {browseFailed && !ssh && (
            <button type="button" className="acpmux-env-button" onClick={() => void browse()} disabled={browsing}>
              {t("project.retry")}
            </button>
          )}
          {environment && onRemove && (
            <button
              type="button"
              className="acpmux-env-button"
              data-destructive=""
              onClick={() => onRemove(environment)}
            >
              {t("environment.remove")}
            </button>
          )}
          <button type="button" className="acpmux-env-button" onClick={onClose}>
            {t("edited.cancel")}
          </button>
          <button type="button" className="acpmux-env-button acpmux-env-submit" disabled={!ready} onClick={save}>
            {environment ? t("artifact.save") : t("environment.create")}
          </button>
        </div>
      </section>
    </KeyboardScope>
  );
}
