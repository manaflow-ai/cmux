import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { ContextMenu } from "../../ui/ContextMenu";
import { Disclosure } from "../../ui/Disclosure";
import { KeyboardScope } from "../../ui/KeyboardScope";
import {
  Menu,
  MenuButton,
  MenuCheckboxItem,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
} from "../../ui/Menu";
import { ChevronIcon } from "./ComposerPickers";
import { FolderIcon } from "./ComposerContext";
import {
  draftReady,
  draftToSave,
  emptyDraft,
  ENVIRONMENT_LIMITS,
  validVariableKey,
  type CloudNetwork,
  type Environment,
  type EnvironmentDraft,
  type EnvironmentFolder,
  type EnvironmentKind,
} from "./environments";
import { FolderPopover, type FolderChoice } from "./FolderPopover";
import { useT } from "./i18n";
import { projectLabel } from "./sessionList";
import "./environments.css";

type Tab = EnvironmentKind | "remote";
const TABS: readonly Tab[] = ["local", "ssh", "cloud", "remote"];
const NETWORKS: readonly CloudNetwork[] = ["none", "limited", "full"];

export type EnvironmentPanelProps = {
  /// The environment to edit; a new one when unset.
  environment?: Environment;
  /// This Mac's recent folders (`project.list`), offered by Add.
  folders: FolderChoice[];
  /// The host's folder panel (`project.browse`): Add's Choose folder….
  onBrowse?(): Promise<string | undefined>;
  /// The machines an SSH environment can name: the Computer menu's other machines.
  machines: { id: string; label: string }[];
  /// A machine's known folders (from its chats), offered by Add on the SSH tab.
  machineFolders(machine: string): FolderChoice[];
  /// The host's connect flows (SSH… on the SSH tab, Connect on the Remote tab).
  onConnect?(kind: "ssh" | "cloud"): void;
  /// Saves through the host; rejects with its reason, which the panel shows.
  onSave(environment: EnvironmentDraft): Promise<void>;
  onRemove?(environment: Environment): void;
  onClose(): void;
};

/// New environment and Edit environment (cx-ncc.104), inline on the New Tab page under the
/// composer, like Add project's panel (AddProjectPanel) and never a modal sheet. Tabs Local / SSH /
/// Cloud / Remote: a name, then the kind's fields; Cancel and Create environment (or Save) at the
/// end. Escape cancels; ⌘↵ saves.
export function EnvironmentPanel({
  environment,
  folders,
  onBrowse,
  machines,
  machineFolders,
  onConnect,
  onSave,
  onRemove,
  onClose,
}: EnvironmentPanelProps) {
  const t = useT();
  const id = useId();
  const [draft, setDraft] = useState<EnvironmentDraft>(() =>
    environment ? structuredClone(environment) : emptyDraft(),
  );
  const [tab, setTab] = useState<Tab>(environment?.kind ?? "local");
  const [domains, setDomains] = useState(() => environment?.cloud?.domains.join(", ") ?? "");
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const name = useRef<HTMLInputElement>(null);
  useEffect(() => name.current?.focus(), []);
  const kind: EnvironmentKind = tab === "remote" ? draft.kind : tab;
  const cloud = draft.cloud ?? { network: "limited" as CloudNetwork, domains: [] };
  const shaped: EnvironmentDraft = {
    ...draft,
    kind,
    ...(kind === "cloud"
      ? { cloud: { ...cloud, domains: domains.split(/[\s,]+/).filter(Boolean) } }
      : { cloud: undefined }),
  };
  const ready = tab !== "remote" && draftReady(shaped) && !saving;
  const update = (change: Partial<EnvironmentDraft>) => setDraft((current) => ({ ...current, ...change }));
  const setFolders = (next: EnvironmentFolder[]) => update({ folders: next });
  const addFolder = (path: string) => {
    if (draft.folders.some((folder) => folder.path === path)) return;
    if (draft.folders.length >= ENVIRONMENT_LIMITS.folders) return;
    setFolders([...draft.folders, { path }]);
  };
  const save = () => {
    if (!ready) return;
    setSaving(true);
    setError(undefined);
    void onSave(draftToSave(shaped))
      .catch((failure: unknown) =>
        setError(t("environment.saveFailed", { reason: failure instanceof Error ? failure.message : String(failure) })),
      )
      .finally(() => setSaving(false));
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
  const tabLabel = (value: Tab) =>
    value === "local"
      ? t("environment.local")
      : value === "ssh"
        ? t("environment.ssh")
        : value === "cloud"
          ? t("composer.cloud")
          : t("environment.remote");
  const host = machines.find((machine) => machine.id === draft.host);
  const showFolders = kind === "local" || kind === "ssh";
  const folderChoices = kind === "ssh" ? (draft.host ? machineFolders(draft.host) : []) : folders;
  return (
    <KeyboardScope handleKeyDown={command}>
      <section
        className="acpmux-env-panel"
        aria-label={environment ? t("environment.edit") : t("environment.new")}
        data-env-tab={tab}
      >
        <div className="acpmux-env-heading">
          <span className="acpmux-env-title">{environment ? t("environment.edit") : t("environment.new")}</span>
          <button type="button" className="acpmux-env-icon-button" onClick={onClose} title={t("project.close")}>
            ×
          </button>
        </div>
        <div className="acpmux-env-tabs" aria-label={t("project.environment")}>
          {TABS.map((value) => (
            <button
              key={value}
              type="button"
              className="acpmux-env-tab"
              aria-pressed={tab === value}
              data-env-tab={value}
              onClick={() => setTab(value)}
            >
              {tabLabel(value)}
            </button>
          ))}
        </div>
        {tab === "remote" ? (
          <div className="acpmux-env-remote">
            <p className="acpmux-env-note">{t("environment.remoteHelp")}</p>
            {onConnect && (
              <div>
                <button type="button" className="acpmux-env-button" onClick={() => onConnect("ssh")}>
                  {t("environment.connect")}
                </button>
              </div>
            )}
          </div>
        ) : (
          <div className="acpmux-env-fields">
            <label className="acpmux-env-field" htmlFor={`${id}-name`}>
              <span className="acpmux-env-label">{t("environment.name")}</span>
              <input
                id={`${id}-name`}
                ref={name}
                className="acpmux-env-input"
                value={draft.name}
                maxLength={ENVIRONMENT_LIMITS.name}
                spellCheck={false}
                autoComplete="off"
                onChange={(event) => update({ name: event.target.value })}
              />
            </label>
            {kind === "ssh" && (
              <div className="acpmux-env-field">
                <span className="acpmux-env-label">{t("environment.host")}</span>
                <Menu>
                  <MenuButton className="acpmux-env-select" label={t("environment.host")}>
                    <span className="acpmux-env-select-text" data-placeholder={host ? undefined : ""}>
                      {host?.label ?? draft.host ?? t("environment.chooseHost")}
                    </span>
                    <ChevronIcon />
                  </MenuButton>
                  <MenuPopup className="acpmux-menu acpmux-location-menu" align="start">
                    {machines.length > 0 && (
                      <MenuRadioGroup
                        value={draft.host ?? ""}
                        onValueChange={(value) => update({ host: value, folders: [] })}
                      >
                        {machines.map((machine) => (
                          <MenuRadioItem key={machine.id} value={machine.id} className="acpmux-menu-item">
                            <span className="acpmux-menu-label">{machine.label}</span>
                          </MenuRadioItem>
                        ))}
                      </MenuRadioGroup>
                    )}
                    {machines.length > 0 && onConnect && <MenuSeparator />}
                    {onConnect && (
                      <MenuItem className="acpmux-menu-item" onSelect={() => onConnect("ssh")}>
                        {t("composer.connectSSH")}
                      </MenuItem>
                    )}
                  </MenuPopup>
                </Menu>
              </div>
            )}
            {showFolders && (
              <div className="acpmux-env-field">
                <div className="acpmux-env-label-row">
                  <span className="acpmux-env-label">{t("environment.folders")}</span>
                  {(kind === "local" || draft.host) && draft.folders.length < ENVIRONMENT_LIMITS.folders && (
                    <FolderPopover
                      label={t("environment.addFolder")}
                      menu="EnvironmentFolder"
                      face={<span className="acpmux-env-add">+ {t("composer.add")}</span>}
                      folders={folderChoices.filter(
                        (choice) => !draft.folders.some((folder) => folder.path === choice.id),
                      )}
                      onPick={addFolder}
                      {...(kind === "local" && onBrowse
                        ? {
                            onBrowse: () => {
                              void onBrowse().then((path) => {
                                if (path) addFolder(path);
                              });
                            },
                          }
                        : {})}
                    />
                  )}
                </div>
                {draft.folders.length === 0 ? (
                  <div className="acpmux-env-empty">
                    {kind === "ssh" && !draft.host ? t("environment.hostFirst") : t("environment.foldersNone")}
                  </div>
                ) : (
                  <ul className="acpmux-env-folders">
                    {draft.folders.map((folder, index) => (
                      <FolderRow
                        key={folder.path}
                        folder={folder}
                        worktrees={kind === "local"}
                        onChange={(next) => setFolders(draft.folders.map((other, at) => (at === index ? next : other)))}
                        onRemove={() => setFolders(draft.folders.filter((_, at) => at !== index))}
                      />
                    ))}
                  </ul>
                )}
              </div>
            )}
            {kind === "cloud" && (
              <>
                <div className="acpmux-env-field">
                  <span className="acpmux-env-label">{t("environment.network")}</span>
                  <div className="acpmux-env-tabs acpmux-env-choices">
                    {NETWORKS.map((network) => (
                      <button
                        key={network}
                        type="button"
                        className="acpmux-env-tab"
                        aria-pressed={cloud.network === network}
                        onClick={() => update({ cloud: { ...cloud, network } })}
                      >
                        {network === "none"
                          ? t("environment.networkNone")
                          : network === "limited"
                            ? t("environment.networkLimited")
                            : t("environment.networkFull")}
                      </button>
                    ))}
                  </div>
                </div>
                {cloud.network === "limited" && (
                  <label className="acpmux-env-field" htmlFor={`${id}-domains`}>
                    <span className="acpmux-env-label">{t("environment.domains")}</span>
                    <input
                      id={`${id}-domains`}
                      className="acpmux-env-input"
                      value={domains}
                      spellCheck={false}
                      autoComplete="off"
                      autoCapitalize="off"
                      onChange={(event) => setDomains(event.target.value)}
                    />
                  </label>
                )}
                <label className="acpmux-env-field" htmlFor={`${id}-setup`}>
                  <span className="acpmux-env-label">{t("environment.setup")}</span>
                  <textarea
                    id={`${id}-setup`}
                    className="acpmux-env-input acpmux-env-script"
                    value={cloud.setup ?? ""}
                    rows={3}
                    spellCheck={false}
                    onChange={(event) => update({ cloud: { ...cloud, setup: event.target.value } })}
                  />
                </label>
                <p className="acpmux-env-note">{t("environment.cloudNote")}</p>
              </>
            )}
            <Variables variables={draft.env} onChange={(env) => update({ env })} />
          </div>
        )}
        <div className="acpmux-env-footer">
          <output className="acpmux-env-error">
            {error ??
              (tab !== "remote" &&
              draft.env.some((variable) => variable.key.trim() && !validVariableKey(variable.key.trim()))
                ? t("environment.variableInvalid")
                : undefined)}
          </output>
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
          {tab !== "remote" && (
            <button type="button" className="acpmux-env-button acpmux-env-submit" disabled={!ready} onClick={save}>
              {environment ? t("artifact.save") : t("environment.create")}
            </button>
          )}
        </div>
      </section>
    </KeyboardScope>
  );
}

/// A folder of the environment: its name (the path on hover), a Worktree tag when it starts in a
/// new worktree, and a ⋮ menu (the same as its right-click menu): Use worktree, Remove.
function FolderRow({
  folder,
  worktrees,
  onChange,
  onRemove,
}: {
  folder: EnvironmentFolder;
  worktrees: boolean;
  onChange(folder: EnvironmentFolder): void;
  onRemove(): void;
}) {
  const t = useT();
  const toggleWorktree = () => onChange({ ...folder, worktree: !folder.worktree });
  return (
    <li className="acpmux-env-folder">
      <ContextMenu
        targets="own"
        items={[
          ...(worktrees ? [{ id: "worktree", label: t("environment.useWorktree"), onSelect: toggleWorktree }] : []),
          { id: "remove", label: t("environment.remove"), destructive: true, onSelect: onRemove },
        ]}
      >
        <span className="acpmux-env-folder-row" title={folder.path}>
          <FolderIcon />
          <span className="acpmux-env-folder-name">{projectLabel(folder.path)}</span>
          {worktrees && folder.worktree && <span className="acpmux-env-tag">{t("sidebar.worktree")}</span>}
          <Menu>
            <MenuButton
              className="acpmux-env-icon-button"
              label={t("environment.folderActions", { name: projectLabel(folder.path) })}
              title={t("environment.folderActions", { name: projectLabel(folder.path) })}
            >
              ⋮
            </MenuButton>
            <MenuPopup className="acpmux-menu acpmux-location-menu" align="end">
              {worktrees && (
                <MenuCheckboxItem
                  className="acpmux-menu-item"
                  checked={folder.worktree === true}
                  onCheckedChange={toggleWorktree}
                >
                  {t("environment.useWorktree")}
                </MenuCheckboxItem>
              )}
              <MenuItem className="acpmux-menu-item" onSelect={onRemove}>
                {t("environment.remove")}
              </MenuItem>
            </MenuPopup>
          </Menu>
        </span>
      </ContextMenu>
    </li>
  );
}

/// Environment variables: one quiet row, "None for this environment" (or how many), that opens to
/// name and value fields.
function Variables({
  variables,
  onChange,
}: {
  variables: EnvironmentDraft["env"];
  onChange(variables: EnvironmentDraft["env"]): void;
}) {
  const t = useT();
  const named = variables.filter((variable) => variable.key.trim());
  return (
    <Disclosure
      className="acpmux-env-variables"
      label={
        <>
          <span className="acpmux-env-label">{t("environment.variables")}</span>
          <span className="acpmux-env-summary">
            {named.length ? named.map((variable) => variable.key.trim()).join(", ") : t("environment.variablesNone")}
          </span>
        </>
      }
    >
      {variables.map((variable, index) => {
        const invalid = variable.key.trim() !== "" && !validVariableKey(variable.key.trim());
        const set = (change: Partial<typeof variable>) =>
          onChange(variables.map((other, at) => (at === index ? { ...other, ...change } : other)));
        return (
          <div key={index} className="acpmux-env-variable" data-invalid={invalid ? "" : undefined}>
            <input
              className="acpmux-env-input"
              aria-label={t("environment.variable")}
              placeholder={t("environment.variable")}
              title={invalid ? t("environment.variableInvalid") : undefined}
              aria-invalid={invalid || undefined}
              value={variable.key}
              spellCheck={false}
              autoComplete="off"
              autoCapitalize="off"
              maxLength={ENVIRONMENT_LIMITS.key}
              onChange={(event) => set({ key: event.target.value })}
            />
            <input
              className="acpmux-env-input"
              aria-label={t("environment.value")}
              placeholder={t("environment.value")}
              value={variable.value}
              spellCheck={false}
              autoComplete="off"
              autoCapitalize="off"
              maxLength={ENVIRONMENT_LIMITS.value}
              onChange={(event) => set({ value: event.target.value })}
            />
            <button
              type="button"
              className="acpmux-env-icon-button"
              title={t("environment.remove")}
              onClick={() => onChange(variables.filter((_, at) => at !== index))}
            >
              ×
            </button>
          </div>
        );
      })}
      {variables.length < ENVIRONMENT_LIMITS.env && (
        <button
          type="button"
          className="acpmux-env-button acpmux-env-add"
          onClick={() => onChange([...variables, { key: "", value: "" }])}
        >
          + {t("composer.add")}
        </button>
      )}
    </Disclosure>
  );
}
