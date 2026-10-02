import React, { useEffect, useMemo, useRef, useState } from "react";
import { agentDisplayName } from "./agents";
import { ArrowUpIcon } from "./ComposerPickers";
import type { AcpmuxSnapshot } from "./model";
import { projectLabel, sessionEntry, sessionMark, type AcpmuxSessionEntry } from "./sessionList";

/// The three things a new tab can become (#16620). Order is the switch's order and Tab's cycle.
export const TAB_KINDS = ["terminal", "browser", "agent"] as const;
export type TabKind = (typeof TAB_KINDS)[number];

/// New tab page copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const NEW_TAB_LABELS = {
  kinds: { terminal: "Terminal", browser: "Browser", agent: "Agent" } satisfies Record<TabKind, string>,
  placeholder: {
    terminal: (folder: string) => (folder ? `Run a command in ${folder}` : "Run a command"),
    browser: () => "Search or type a URL",
    agent: (agent: string) => `Ask ${agent} to build, fix or explain`,
  } satisfies Record<TabKind, (name: string) => string>,
  switchHint: "to switch",
  switchLabel: "Open as",
  editShortcut: (kind: string, keys: string) => `${kind} (${keys}). Right-click to change the shortcut`,
  open: "Open",
  recent: "Recent",
  allSessions: "All sessions",
  thisMac: "This Mac",
  noRecent: "Chats you start show up here.",
  status: { input: "Needs input", running: "Running", error: "Failed", unread: "Unread" } satisfies Record<
    NonNullable<ReturnType<typeof sessionMark>>,
    string
  >,
};

/// What the host's handshake says about a tab opened as a new tab page.
export type NewTabHost = {
  hotkeys: Partial<Record<TabKind, string>>;
  initialKind: TabKind;
  cwd?: string;
  host?: string;
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
  return {
    hotkeys,
    initialKind,
    ...(cwd ? { cwd } : {}),
    ...(typeof object.host === "string" ? { host: object.host } : {}),
  };
}

/// How many recent sessions the page shows (two rows of three).
export const RECENT_COUNT = 6;

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
export function ageLabel(updatedAt: number | undefined, now = Date.now()): string {
  if (!updatedAt) return "";
  const minutes = Math.max(0, Math.round((now - updatedAt) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  return hours < 24 ? `${hours}h` : `${Math.round(hours / 24)}d`;
}

type Props = {
  snapshot: AcpmuxSnapshot;
  /// Each kind's shortcut as the host shows it ("⌃⇧⌘T"); a kind without one shows none.
  hotkeys?: Partial<Record<TabKind, string>>;
  /// The kind selected when the page opens.
  initialKind?: TabKind;
  /// The folder the new tab starts in (the pane's terminal cwd).
  cwd?: string;
  /// The machine it runs on; "This Mac" when absent.
  host?: string;
  /// The agent's composer chips (model, mode), shown under the field for Agent.
  chips?: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  onSubmit(kind: TabKind, text: string): void;
  onOpenSession(sessionId: string): void;
  onShowAll(): void;
  onEditShortcut?(kind: TabKind): void;
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
  onSubmit,
  onOpenSession,
  onShowAll,
  onEditShortcut,
  now,
}: Props) {
  const [kind, setKind] = useState<TabKind>(initialKind);
  const [text, setText] = useState("");
  const field = useRef<HTMLInputElement>(null);
  const composing = useRef(false);
  const recent = useMemo(() => recentSessions(snapshot.sessions), [snapshot.sessions]);
  // A pane without a known folder names none rather than showing "No folder".
  const folder = cwd ? projectLabel(cwd) : "";
  const agent = agentDisplayName(snapshot.summary?.harness ?? snapshot.catalog[0]?.id ?? "agent");
  const placeholder = NEW_TAB_LABELS.placeholder[kind](kind === "agent" ? agent : folder);

  // The field takes the keyboard when the page appears, as a browser's new tab does.
  useEffect(() => {
    field.current?.focus();
  }, []);
  const choose = (next: TabKind) => {
    setKind(next);
    field.current?.focus();
  };
  const submit = (event?: React.FormEvent) => {
    event?.preventDefault();
    // An empty terminal or agent opens as it is; an empty page has nothing to load.
    if (kind === "browser" && !text.trim()) return;
    onSubmit(kind, text.trim());
  };
  const keyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (composing.current || event.nativeEvent.isComposing) return;
    if (event.key === "Tab" && !event.altKey && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      setKind((current) => cycleKind(current, event.shiftKey ? -1 : 1));
    }
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
            spellCheck={kind === "agent"}
            autoCapitalize="off"
            autoCorrect="off"
            onChange={(event) => setText(event.target.value)}
            onKeyDown={keyDown}
            onCompositionStart={() => {
              composing.current = true;
            }}
            onCompositionEnd={() => {
              composing.current = false;
            }}
          />
          <fieldset className="acpmux-newtab-switch" aria-label={NEW_TAB_LABELS.switchLabel}>
            {TAB_KINDS.map((option) => (
              <button
                key={option}
                type="button"
                aria-pressed={option === kind}
                tabIndex={-1}
                className={option === kind ? "acpmux-newtab-kind is-selected" : "acpmux-newtab-kind"}
                title={
                  hotkeys[option]
                    ? NEW_TAB_LABELS.editShortcut(NEW_TAB_LABELS.kinds[option], hotkeys[option]!)
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
                <span>{NEW_TAB_LABELS.kinds[option]}</span>
                {hotkeys[option] && <kbd>{hotkeys[option]}</kbd>}
              </button>
            ))}
          </fieldset>
        </div>
        <div className="acpmux-newtab-under">
          <span className="acpmux-newtab-context">
            {kind === "browser" || !folder ? null : (
              <span className="acpmux-newtab-chip">
                <FolderIcon />
                {folder}
              </span>
            )}
            {kind === "terminal" && (
              <span className="acpmux-newtab-chip">
                <LaptopIcon />
                {host ?? NEW_TAB_LABELS.thisMac}
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
          <span className="acpmux-newtab-hint" aria-hidden="true">
            <kbd>Tab</kbd> {NEW_TAB_LABELS.switchHint}
          </span>
          <button
            type="submit"
            className={`acpmux-send${text.trim() || kind !== "browser" ? " acpmux-send-ready" : ""}`}
            aria-label={NEW_TAB_LABELS.open}
            title={NEW_TAB_LABELS.open}
          >
            <ArrowUpIcon />
          </button>
        </div>
      </form>
      <section className="acpmux-newtab-recent" aria-label={NEW_TAB_LABELS.recent}>
        <header>
          <span>{NEW_TAB_LABELS.recent}</span>
          <button type="button" className="acpmux-newtab-all" onClick={onShowAll}>
            {NEW_TAB_LABELS.allSessions}
            <ChevronRight />
          </button>
        </header>
        {recent.length === 0 ? (
          <p className="acpmux-newtab-empty">{NEW_TAB_LABELS.noRecent}</p>
        ) : (
          <ul>
            {recent.map((session) => (
              <li key={session.sessionId}>
                <SessionCard session={session} now={now} onOpen={() => onOpenSession(session.sessionId)} />
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

function SessionCard({ session, now, onOpen }: { session: AcpmuxSessionEntry; now?: number; onOpen(): void }) {
  const mark = sessionMark(session, false);
  const agent = agentDisplayName(session.harness ?? "agent");
  return (
    <button type="button" className="acpmux-newtab-card" onClick={onOpen}>
      <span className="acpmux-newtab-card-top">
        <span className={`acpmux-newtab-dot${mark ? ` is-${mark}` : ""}`} aria-hidden="true" />
        <span className="acpmux-newtab-card-meta">{mark ? `${NEW_TAB_LABELS.status[mark]} · ${agent}` : agent}</span>
        <span className="acpmux-newtab-card-age">{ageLabel(session.updatedAt, now)}</span>
      </span>
      <span className="acpmux-newtab-card-title">{session.displayTitle}</span>
      {session.preview && <span className="acpmux-newtab-card-preview">{session.preview}</span>}
      <span className="acpmux-newtab-card-foot">
        <span className="acpmux-newtab-card-tag">
          <FolderIcon />
          {projectLabel(session.cwd)}
        </span>
        {session.branch && (
          <span className="acpmux-newtab-card-tag">
            <BranchIcon />
            {session.branch}
          </span>
        )}
        {session.hostKind === "cloud" && session.host && (
          <span className="acpmux-newtab-card-tag">
            <CloudIcon />
            {session.host}
          </span>
        )}
      </span>
    </button>
  );
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
const BranchIcon = () => (
  <Icon>
    <circle cx="4.5" cy="3.6" r="1.5" />
    <circle cx="4.5" cy="12.4" r="1.5" />
    <circle cx="11.5" cy="5.6" r="1.5" />
    <path d="M4.5 5.1v5.8M11.5 7.1c0 2.4-2.3 2.9-7 3.8" />
  </Icon>
);
const CloudIcon = () => (
  <Icon>
    <path d="M4.6 12.4h7a2.9 2.9 0 0 0 .3-5.8 4.1 4.1 0 0 0-7.9 1A2.4 2.4 0 0 0 4.6 12.4Z" />
  </Icon>
);
const ChevronRight = () => (
  <Icon>
    <path d="m6.3 4.6 3.3 3.4-3.3 3.4" />
  </Icon>
);
