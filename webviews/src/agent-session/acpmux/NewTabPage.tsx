import React, { useEffect, useMemo, useRef, useState } from "react";
import { AgentMark as BrandMark } from "../shared/AgentMark";
import { agentBrand } from "../shared/agentBrand";
import { agentDisplayName } from "./agents";
import { ArrowUpIcon } from "./ComposerPickers";
import type { AcpmuxSnapshot } from "./model";
import { ProjectChooser, type Project } from "./ProjectChooser";
import {
  defaultRow,
  EMPTY_OMNIBAR,
  MAX_NEW_TAB_ENTRIES,
  omnibarContext,
  omnibarRows,
  type OmnibarContext,
  type OmnibarRow,
} from "./omnibar";
import { homePath, projectLabel, sessionEntry, sessionMark, type AcpmuxSessionEntry } from "./sessionList";
import { type StringKey, type Translate, translate, useT } from "./i18n";

/// The three things a new tab can become (#16620). Order is the switch's order and Tab's cycle.
export const TAB_KINDS = ["terminal", "browser", "agent"] as const;
export type TabKind = (typeof TAB_KINDS)[number];

/// The event the host dispatches on `window` for Focus Location Bar (Cmd-L).
export const FOCUS_LOCATION_EVENT = "acpmux-focus-location";

/// What Cmd-T and + open (`tabs.newTabKind`), in the order the "default" toggle cycles.
export const DEFAULT_KINDS = ["same-kind", "terminal", "browser", "agent", "page", "auto"] as const;
export type DefaultKind = (typeof DEFAULT_KINDS)[number];

/// New tab page copy: keys of the pane's string table.
export const NEW_TAB_LABELS = {
  kinds: {
    terminal: "newTabPage.kind.terminal",
    browser: "newTabPage.kind.browser",
    agent: "newTabPage.kind.agent",
  } satisfies Record<TabKind, StringKey>,
  placeholder: {
    terminal: (t: Translate, folder: string) =>
      folder ? t("newTabPage.placeholder.terminalIn", { folder }) : t("newTabPage.placeholder.terminal"),
    browser: (t: Translate) => t("newTabPage.placeholder.browser"),
    agent: (t: Translate, agent: string) => t("newTabPage.placeholder.agent", { agent }),
  } satisfies Record<TabKind, (t: Translate, name: string) => string>,
  switchLabel: "newTabPage.switchLabel",
  /// `{kind}` is a tab kind's name, `{keys}` its shortcut.
  editShortcut: "newTabPage.editShortcut",
  open: "newTabPage.open",
  suggestions: "newTabPage.suggestions",
  rows: {
    tab: "newTabPage.row.tab",
    workspace: "newTabPage.row.workspace",
    session: "newTabPage.row.session",
    folder: "newTabPage.row.folder",
    command: "newTabPage.row.command",
    history: "newTabPage.row.history",
    run: "newTabPage.row.run",
    open: "newTabPage.row.open",
  } satisfies Record<Exclude<OmnibarRow["type"], "ask">, StringKey>,
  ask: "newTabPage.ask",
  /// `{kind}` is one of `defaultKinds`.
  defaultKind: "newTabPage.defaultKind",
  defaultKinds: {
    "same-kind": "newTabPage.defaultKind.sameKind",
    terminal: "newTabPage.defaultKind.terminal",
    browser: "newTabPage.defaultKind.browser",
    agent: "newTabPage.defaultKind.agent",
    page: "newTabPage.defaultKind.page",
    auto: "newTabPage.defaultKind.auto",
  } satisfies Record<DefaultKind, StringKey>,
  defaultKindHint: "newTabPage.defaultKindHint",
  allSessions: "newTabPage.allSessions",
  thisMac: "newTabPage.thisMac",
} as const;

/// What the host's handshake says about a tab opened as a new tab page.
export type NewTabHost = {
  hotkeys: Partial<Record<TabKind, string>>;
  initialKind: TabKind;
  cwd?: string;
  host?: string;
  location?: string;
  /// Project folders found by the host scan, before session-derived folders.
  projects?: string[];
  omnibar?: OmnibarContext;
  defaultKind?: DefaultKind;
  /// Which design (Debug Settings `newTab.layout`): "b" the one-input screen (default),
  /// "a" this Terminal | Browser | Agent page, kept until B passes dogfood (decision Q6).
  layout: "a" | "b";
  /// The agent last picked (decision Q3).
  lastAgent?: string;
  /// The home folder, so `~/path` reads as a folder.
  home?: string;
};

/// Reads `newTab` from the handshake: `true`, or `{hotkeys, kind, cwd, host}`. Nil for a plain chat.
export function newTabHost(handshake: { newTab?: unknown; cwd?: unknown }): NewTabHost | undefined {
  const value = handshake.newTab;
  if (value !== true && (typeof value !== "object" || value === null)) return undefined;
  const object = (typeof value === "object" ? value : {}) as Record<string, unknown>;
  const keys = (typeof object.hotkeys === "object" && object.hotkeys !== null ? object.hotkeys : {}) as Record<
    string,
    unknown
  >;
  const hotkeys: Partial<Record<TabKind, string>> = {};
  for (const kind of TAB_KINDS) if (typeof keys[kind] === "string" && keys[kind]) hotkeys[kind] = keys[kind] as string;
  const initialKind = TAB_KINDS.includes(object.kind as TabKind) ? (object.kind as TabKind) : "agent";
  const cwd =
    typeof object.cwd === "string" ? object.cwd : typeof handshake.cwd === "string" ? handshake.cwd : undefined;
  const omnibar = omnibarContext(object.omnibar);
  return {
    hotkeys,
    initialKind,
    ...(cwd ? { cwd } : {}),
    ...(typeof object.host === "string" ? { host: object.host } : {}),
    ...(typeof object.location === "string" && object.location ? { location: object.location } : {}),
    ...(omnibar ? { omnibar } : {}),
    ...(Array.isArray(object.projects)
      ? {
          projects: object.projects
            .filter((path): path is string => typeof path === "string" && path.length > 0)
            .slice(0, MAX_NEW_TAB_ENTRIES),
        }
      : {}),
    ...(DEFAULT_KINDS.includes(object.defaultKind as DefaultKind)
      ? { defaultKind: object.defaultKind as DefaultKind }
      : {}),
    layout: object.layout === "a" ? "a" : "b",
    ...(typeof object.lastAgent === "string" && object.lastAgent ? { lastAgent: object.lastAgent } : {}),
    ...(typeof object.home === "string" && object.home.startsWith("/") ? { home: object.home } : {}),
  };
}

/// How many recent sessions the page shows (two rows of three).
export const RECENT_COUNT = 6;

/// A leading character that switches the field to a kind as it is typed, as `!` does in
/// Claude Code: `!` runs a command in a terminal, `?` asks the agent. `@` is left to the
/// agent composer, which uses it for file mentions.
export const KIND_PREFIXES: Readonly<Record<string, TabKind>> = { "!": "terminal", "?": "agent" };

/// The kind a field edit switches to and the text it keeps: typing a prefix into an
/// empty field switches and consumes it; anything else stays as typed.
export function prefixedEdit(previous: string, next: string): { kind: TabKind; text: string } | undefined {
  if (previous !== "" || next.length === 0) return undefined;
  const kind = KIND_PREFIXES[next[0]!];
  return kind ? { kind, text: next.slice(1) } : undefined;
}

/// The next kind for Tab (or Shift+Tab with `step` -1), wrapping.
export function cycleKind(kind: TabKind, step = 1): TabKind {
  const index = TAB_KINDS.indexOf(kind);
  return TAB_KINDS[(index + step + TAB_KINDS.length) % TAB_KINDS.length]!;
}

/// The newest sessions first, the ones waiting on the user ahead of them.
export function recentSessions(sessions: AcpmuxSnapshot["sessions"], count = RECENT_COUNT): AcpmuxSessionEntry[] {
  const entries = sessions.map((session) => sessionEntry(session as AcpmuxSessionEntry & Record<string, unknown>));
  const urgency = (entry: AcpmuxSessionEntry) => (sessionMark(entry, false) === "input" ? 0 : 1);
  return entries.sort((a, b) => urgency(a) - urgency(b) || (b.updatedAt ?? 0) - (a.updatedAt ?? 0)).slice(0, count);
}

/// "now", "5m", "3h", "2d": the card's age, as compact as the sidebar's.
export function ageLabel(updatedAt: number | undefined, now = Date.now(), t: Translate = translate): string {
  if (!updatedAt) return "";
  const minutes = Math.max(0, Math.round((now - updatedAt) / 60_000));
  if (minutes < 1) return t("age.now");
  if (minutes < 60) return t("age.minutes", { n: minutes });
  const hours = Math.round(minutes / 60);
  return hours < 24 ? t("age.hours", { n: hours }) : t("age.days", { n: Math.round(hours / 24) });
}

type Props = {
  snapshot: AcpmuxSnapshot;
  /// Each kind's shortcut as the host shows it ("⌃⇧⌘T"); a kind without one shows none.
  hotkeys?: Partial<Record<TabKind, string>>;
  /// The kind selected when the page opens.
  initialKind?: TabKind;
  /// The folder the new tab starts in (the pane's terminal cwd).
  cwd?: string;
  /// The machine it runs on (the handshake's `machineName`); "This Mac" when absent.
  host?: string;
  /// The agent's composer chips (model, mode), shown under the field for Agent.
  chips?: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  /// Open tabs, workspaces, folders, commands and history the bar suggests.
  omnibar?: OmnibarContext;
  /// The current tab's URL or folder: in the field and selected when the page opens,
  /// so typing replaces it.
  location?: string;
  /// What Cmd-T opens; the "default" toggle shows it when the host sends it.
  defaultKind?: DefaultKind;
  /// The toggle picked the next default.
  onSetDefaultKind?(kind: DefaultKind): void;
  /// Recent projects are offered inline before Browse is needed.
  projects?: Project[];
  /// Make the tab `kind`: run `text` (in `cwd`), open it, or ask it.
  onSubmit(kind: TabKind, text: string, cwd?: string): void;
  /// Go to an open tab or workspace instead of opening a duplicate.
  onJump?(target: "tab" | "workspace", id: string): void;
  onOpenSession(sessionId: string): void;
  onShowAll(): void;
  onEditShortcut?(kind: TabKind): void;
  onImport?(): void;
  onBrowseProject?(): void;
  now?: number;
};

/// A new tab before it is anything: one field, a Terminal | Browser | Agent switch that
/// Tab cycles, each option with its own shortcut, and the recent sessions below. Enter
/// makes the tab that kind: a terminal running the command, a page, or a chat.
export function NewTabPage({
  snapshot,
  hotkeys = {},
  initialKind = "agent",
  cwd,
  host,
  chips: Chips,
  omnibar = EMPTY_OMNIBAR,
  location,
  defaultKind: initialDefault,
  onSetDefaultKind,
  projects = [],
  onSubmit,
  onJump,
  onOpenSession,
  onShowAll,
  onEditShortcut,
  onImport,
  onBrowseProject,
}: Props) {
  const t = useT();
  const [kind, setKind] = useState<TabKind>(initialKind);
  const [defaultKind, setDefaultKind] = useState(initialDefault);
  const [projectCwd, setProjectCwd] = useState(cwd);
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: the rows are the empty bar's.
  const [touched, setTouched] = useState(false);
  const query = touched ? text : "";
  const [selected, setSelected] = useState(-1);
  // The field was wholly selected before this edit, so a typed prefix starts it over.
  const replacing = useRef(false);
  const list = useRef<HTMLDivElement>(null);
  // The kind a prefix switched from, so Backspace in the empty field switches back.
  const [beforePrefix, setBeforePrefix] = useState<TabKind>();
  const field = useRef<HTMLInputElement>(null);
  const composing = useRef(false);
  const recent = useMemo(() => recentSessions(snapshot.sessions), [snapshot.sessions]);
  const rows = useMemo(
    () =>
      omnibarRows(query, kind, {
        ...omnibar,
        sessions: recent.map((session) => ({
          sessionId: session.sessionId,
          title: session.displayTitle ?? session.sessionId,
          ...(session.harness ? { harness: session.harness } : {}),
          detail: projectLabel(session.cwd),
        })),
      }),
    [query, kind, omnibar, recent],
  );
  useEffect(() => setSelected(defaultRow(rows, kind, query)), [rows, kind, query]);
  useEffect(() => {
    list.current?.querySelector<HTMLElement>(`#acpmux-omni-${selected}`)?.scrollIntoView?.({ block: "nearest" });
  }, [selected]);
  // A pane without a known folder names none rather than showing "No folder".
  const selectedProject = projectCwd ? projectLabel(projectCwd) : undefined;
  const folder = projectCwd ? projectLabel(projectCwd) : "";
  const agent = agentDisplayName(snapshot.summary?.harness ?? snapshot.catalog[0]?.id ?? "agent");
  const placeholder = NEW_TAB_LABELS.placeholder[kind](t, kind === "agent" ? agent : folder);

  // The field takes the keyboard when the page appears, as a browser's new tab does, and
  // again on Cmd-L (the host's FOCUS_LOCATION_EVENT), wherever focus moved on the page.
  useEffect(() => {
    const focus = () => {
      field.current?.focus();
      field.current?.select();
    };
    focus();
    const host = field.current?.ownerDocument.defaultView;
    host?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => host?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
  }, []);
  const choose = (next: TabKind) => {
    setKind(next);
    setBeforePrefix(undefined);
    field.current?.focus();
  };
  const activate = (row: OmnibarRow) => {
    switch (row.type) {
      case "tab":
      case "workspace":
        return onJump?.(row.type, row.id);
      case "session":
        return onOpenSession(row.id);
      case "folder":
        return onSubmit("terminal", "", row.path);
      case "command":
        return onSubmit("terminal", row.command, projectCwd);
      case "history":
        return onSubmit("browser", row.url);
      case "run":
        return onSubmit("terminal", row.text, projectCwd);
      case "open":
        return onSubmit("browser", row.text);
      case "ask":
        return onSubmit("agent", row.text, projectCwd);
    }
  };
  const submit = (event?: React.FormEvent) => {
    event?.preventDefault();
    const row = rows[selected];
    if (row) return activate(row);
    // An empty terminal or agent opens as it is; an empty page has nothing to load.
    if (kind === "browser" && !query.trim()) return;
    onSubmit(kind, query.trim(), kind === "browser" ? undefined : projectCwd);
  };
  const keyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (composing.current || event.nativeEvent.isComposing) return;
    const input = event.currentTarget;
    replacing.current = input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    if ((event.key === "ArrowDown" || event.key === "ArrowUp") && rows.length) {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setSelected((current) =>
        current < 0 && step < 0 ? rows.length - 1 : (current + step + rows.length) % rows.length,
      );
    } else if (event.key === "Escape" && text) {
      event.preventDefault();
      setText("");
      setTouched(true);
    } else if (event.key === "Tab" && !event.altKey && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      setBeforePrefix(undefined);
      setKind((current) => cycleKind(current, event.shiftKey ? -1 : 1));
    } else if (event.key === "Backspace" && text === "" && beforePrefix) {
      event.preventDefault();
      setKind(beforePrefix);
      setBeforePrefix(undefined);
    }
  };
  const edit = (next: string) => {
    setTouched(true);
    const prefixed = composing.current ? undefined : prefixedEdit(replacing.current ? "" : text, next);
    replacing.current = false;
    if (prefixed && prefixed.kind !== kind) {
      setBeforePrefix(kind);
      setKind(prefixed.kind);
      setText(prefixed.text);
      return;
    }
    setText(next);
  };

  return (
    <div className="acpmux-newtab" data-kind={kind}>
      <form className="acpmux-newtab-box" onSubmit={submit}>
        <div className="acpmux-newtab-row">
          <KindIcon kind={kind} />
          <input
            ref={field}
            className="acpmux-newtab-field"
            aria-label={placeholder}
            placeholder={placeholder}
            value={text}
            aria-controls="acpmux-omni"
            aria-activedescendant={selected >= 0 ? `acpmux-omni-${selected}` : undefined}
            spellCheck={kind === "agent"}
            autoCapitalize="off"
            autoCorrect="off"
            onChange={(event) => edit(event.target.value)}
            onKeyDown={keyDown}
            onCompositionStart={() => {
              composing.current = true;
            }}
            onCompositionEnd={() => {
              composing.current = false;
            }}
          />
          <fieldset className="acpmux-newtab-switch" aria-label={t(NEW_TAB_LABELS.switchLabel)}>
            {TAB_KINDS.map((option) => (
              <button
                key={option}
                type="button"
                aria-pressed={option === kind}
                tabIndex={-1}
                className={option === kind ? "acpmux-newtab-kind is-selected" : "acpmux-newtab-kind"}
                title={
                  hotkeys[option]
                    ? t(NEW_TAB_LABELS.editShortcut, { kind: t(NEW_TAB_LABELS.kinds[option]), keys: hotkeys[option]! })
                    : undefined
                }
                onClick={() => choose(option)}
                onContextMenu={(event) => {
                  if (!onEditShortcut) return;
                  event.preventDefault();
                  onEditShortcut(option);
                }}
              >
                <KindIcon kind={option} />
                <span>{t(NEW_TAB_LABELS.kinds[option])}</span>
                {hotkeys[option] && <kbd>{hotkeys[option]}</kbd>}
              </button>
            ))}
          </fieldset>
        </div>
        <div className="acpmux-newtab-under">
          <span className="acpmux-newtab-context">
            {kind !== "browser" && (
              <ProjectChooser
                projects={projects}
                current={projectCwd}
                currentLabel={selectedProject}
                icon={<FolderIcon />}
                onPick={setProjectCwd}
                onBrowse={onBrowseProject}
              />
            )}
            {kind === "terminal" && (
              <span className="acpmux-newtab-chip">
                <LaptopIcon />
                {host ?? t(NEW_TAB_LABELS.thisMac)}
              </span>
            )}
            {kind === "agent" && (
              <span className="acpmux-newtab-chip">
                <KindIcon kind="agent" />
                {agent}
              </span>
            )}
            {kind === "agent" && Chips && <Chips snapshot={snapshot} />}
          </span>
          {defaultKind && onSetDefaultKind && (
            <button
              type="button"
              className="acpmux-newtab-default"
              title={t(NEW_TAB_LABELS.defaultKindHint)}
              onClick={() => {
                const next = DEFAULT_KINDS[(DEFAULT_KINDS.indexOf(defaultKind) + 1) % DEFAULT_KINDS.length]!;
                setDefaultKind(next);
                onSetDefaultKind(next);
              }}
            >
              {t(NEW_TAB_LABELS.defaultKind, { kind: t(NEW_TAB_LABELS.defaultKinds[defaultKind]) })}
            </button>
          )}
          <button
            type="submit"
            className={`acpmux-send${query.trim() || kind !== "browser" ? " acpmux-send-ready" : ""}`}
            aria-label={t(NEW_TAB_LABELS.open)}
            title={`${t(NEW_TAB_LABELS.open)} ↵`}
          >
            <ArrowUpIcon />
          </button>
        </div>
      </form>
      {rows.length > 0 && (
        <div
          ref={list}
          className="acpmux-omni"
          id="acpmux-omni"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="listbox"
          aria-label={t(NEW_TAB_LABELS.suggestions)}
        >
          {/* Virtual focus, as the composer's slash menu: the field keeps focus and names the row. */}
          {rows.map((row, index) => (
            <div
              key={rowKey(row)}
              id={`acpmux-omni-${index}`}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === selected}
              className={index === selected ? "acpmux-omni-row is-selected" : "acpmux-omni-row"}
              onMouseMove={() => index !== selected && setSelected(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                activate(row);
              }}
            >
              <RowIcon row={row} agent={snapshot.summary?.harness ?? snapshot.catalog[0]?.id} />
              <span className="acpmux-omni-text">
                <span className="acpmux-omni-title">
                  {row.type === "ask" && <b>{t(NEW_TAB_LABELS.ask, { agent })}: </b>}
                  {rowTitle(row)}
                </span>
                {rowDetail(row) && <span className="acpmux-omni-detail">{rowDetail(row)}</span>}
              </span>
              <span className="acpmux-omni-action">
                {row.type === "ask" ? t(NEW_TAB_LABELS.ask, { agent }) : t(NEW_TAB_LABELS.rows[row.type])}
                {index === selected && <kbd>↵</kbd>}
              </span>
            </div>
          ))}
        </div>
      )}
      <div className="acpmux-newtab-actions">
        <button type="button" className="acpmux-newtab-all" onClick={onShowAll}>
          {t(NEW_TAB_LABELS.allSessions)}
          <ChevronRight />
        </button>
        {onImport && (
          <button type="button" className="acpmux-newtab-all" onClick={onImport}>
            {t("newtab.importAndSync")}
          </button>
        )}
      </div>
    </div>
  );
}

function rowKey(row: OmnibarRow): string {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return `${row.type}:${row.id}`;
    case "folder":
      return `folder:${row.path}`;
    case "command":
      return `command:${row.command}`;
    case "history":
      return `history:${row.url}`;
    default:
      return row.type;
  }
}

function rowTitle(row: OmnibarRow): string {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return row.title;
    case "folder":
      return projectLabel(row.path);
    case "command":
      return row.command;
    case "history":
      return row.title || row.url;
    default:
      return row.text;
  }
}

function rowDetail(row: OmnibarRow): string | undefined {
  switch (row.type) {
    case "tab":
    case "workspace":
    case "session":
      return row.detail;
    case "folder":
      return homePath(row.path);
    case "history":
      return row.title ? row.url.replace(/^https?:\/\//, "") : undefined;
    default:
      return undefined;
  }
}

function RowIcon({ row, agent }: { row: OmnibarRow; agent?: string }) {
  switch (row.type) {
    case "tab":
      return <KindIcon kind={row.kind} />;
    case "workspace":
      return <WorkspaceIcon />;
    case "session":
      return <AgentMark harness={row.harness} />;
    case "folder":
      return <FolderIcon />;
    case "command":
    case "run":
      return <KindIcon kind="terminal" />;
    case "history":
      return <ClockIcon />;
    case "open":
      return <KindIcon kind="browser" />;
    case "ask":
      return <AgentMark harness={agent} />;
  }
}

/// The agent's brand mark (design/agent-icons), so a session's row says which agent it
/// is at a glance; an agent without a mark draws the generic agent glyph.
export function AgentMark({ harness }: { harness?: string }) {
  return agentBrand(harness) ? <BrandMark agent={harness} size={16} /> : <KindIcon kind="agent" />;
}

// 16px stroke icons in currentColor, matching ComposerPickers.
function Icon({ children }: { children: React.ReactNode }) {
  return (
    <svg
      className="acpmux-icon"
      width={16}
      height={16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

export function KindIcon({ kind }: { kind: TabKind }) {
  switch (kind) {
    case "terminal":
      return (
        <Icon>
          <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2" />
          <path d="m4.6 6.2 2 1.8-2 1.8M8.4 10h3" />
        </Icon>
      );
    case "browser":
      return (
        <Icon>
          <circle cx="8" cy="8" r="6.1" />
          <path d="M1.9 8h12.2M8 1.9c1.7 1.7 2.5 3.7 2.5 6.1S9.7 12.4 8 14.1C6.3 12.4 5.5 10.4 5.5 8S6.3 3.6 8 1.9Z" />
        </Icon>
      );
    case "agent":
      return (
        <Icon>
          <path d="M8 1.9c.4 2.9 1.6 4.1 4.6 4.6-3 .5-4.2 1.7-4.6 4.6-.4-2.9-1.6-4.1-4.6-4.6 3-.5 4.2-1.7 4.6-4.6Z" />
          <path d="M12.4 10.4c.15 1.1.6 1.55 1.7 1.7-1.1.15-1.55.6-1.7 1.7-.15-1.1-.6-1.55-1.7-1.7 1.1-.15 1.55-.6 1.7-1.7Z" />
        </Icon>
      );
  }
}

const FolderIcon = () => (
  <Icon>
    <path d="M1.9 4.6c0-.8.6-1.4 1.4-1.4h2.6l1.5 1.6h5.3c.8 0 1.4.6 1.4 1.4v5.6c0 .8-.6 1.4-1.4 1.4H3.3c-.8 0-1.4-.6-1.4-1.4Z" />
  </Icon>
);
const LaptopIcon = () => (
  <Icon>
    <rect x="3" y="3.4" width="10" height="7" rx="1.2" />
    <path d="M1.6 12.6h12.8" />
  </Icon>
);
const WorkspaceIcon = () => (
  <Icon>
    <rect x="2" y="2.6" width="12" height="10.8" rx="2" />
    <path d="M6.2 2.6v10.8" />
  </Icon>
);
const ClockIcon = () => (
  <Icon>
    <circle cx="8" cy="8" r="6.1" />
    <path d="M8 4.6V8l2.3 1.5" />
  </Icon>
);
const ChevronRight = () => (
  <Icon>
    <path d="m6.3 4.6 3.3 3.4-3.3 3.4" />
  </Icon>
);
