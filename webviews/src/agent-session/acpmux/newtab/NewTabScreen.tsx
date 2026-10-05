import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ProjectChooser, type Project } from "../ProjectChooser";
import { AgentMark, FOCUS_LOCATION_EVENT } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { ChatCards } from "./ChatCards";
import { orderedAgents, recentChatCards, screenRows, terminalConversion, type ScreenRow } from "./screenModel";
import { type NewTabTranslate, useNt } from "./strings";
import { useT } from "../i18n";

/// What the screen asks the host to do. Agent rows stay in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  onAsk(harness: string, text: string, cwd?: string): void;
  onOpen(url: string): void;
  onSearch(text: string): void;
  /// `!` was typed: the tab becomes a terminal now, `command` typed at its prompt.
  onTerminal(command: string, cwd?: string): void;
  /// The command as typed since `onTerminal`, whole each time, until the terminal has focus.
  onTypeAhead(command: string): void;
  onJump(target: "tab" | "workspace", id: string): void;
  onOpenSession(sessionId: string): void;
  onShowAll(): void;
  onAction?(id: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
};

type Props = NewTabScreenActions & {
  snapshot: AcpmuxSnapshot;
  omnibar?: OmnibarContext;
  /// The tab the page opened from (its URL or folder): in the field and selected.
  location?: string;
  lastAgent?: string;
  home?: string;
  now?: number;
  cwd?: string;
  projects?: Project[];
  loadProjects?(): Promise<Project[]>;
  onBrowseProject?(): Promise<string | undefined>;
  onImport?(): void;
};

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): one field that reads what is
/// typed (`!` a terminal, an address, or a prompt with the installed agents and a web search
/// row under it; no Search/Ask mode, R86), and the recent chats as cards.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  const t = useT();
  const [projectCwd, setProjectCwd] = useState(props.cwd);
  const [projects, setProjects] = useState(props.projects ?? []);
  const loadProjects = props.loadProjects;
  useEffect(() => {
    if (!loadProjects) return;
    let cancelled = false;
    void loadProjects()
      .then((next) => {
        if (!cancelled) setProjects(next);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [loadProjects]);
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now } = props;
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  const [selected, setSelected] = useState(0);
  const [converting, setConverting] = useState(false);
  const field = useRef<HTMLInputElement>(null);
  const wholeSelection = useRef(false);
  const composing = useRef(false);
  const inputReported = useRef(false);
  const touch = () => {
    if (inputReported.current) return;
    inputReported.current = true;
    props.onTouched?.();
  };
  const agents = useMemo(
    () => snapshot.catalog.map((entry) => ({ id: entry.id, name: entry.name })),
    [snapshot.catalog],
  );
  const rows = useMemo(
    () => (touched && !converting ? screenRows(text, { agents, omnibar, lastAgent, home }) : []),
    [touched, converting, text, agents, omnibar, lastAgent, home],
  );
  const cards = useMemo(() => recentChatCards(snapshot.sessions, now, t), [snapshot.sessions, now, t]);
  useEffect(() => setSelected(0), [rows]);

  // The field takes the keyboard when the screen appears (in the commit, so an adopted spare's
  // field has focus before the next key) and on Cmd-L (FOCUS_LOCATION_EVENT).
  useLayoutEffect(() => {
    const focus = () => {
      field.current?.focus();
      field.current?.select();
    };
    focus();
    const view = field.current?.ownerDocument.defaultView;
    view?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => view?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
  }, []);

  const activate = (row: ScreenRow) => {
    switch (row.type) {
      case "agent":
        return projectCwd ? props.onAsk(row.harness, row.text, projectCwd) : props.onAsk(row.harness, row.text);
      case "search":
        return props.onSearch(row.text);
      case "open":
        return props.onOpen(row.url);
      case "history":
        return props.onOpen(row.url);
      case "tab":
      case "workspace":
        return props.onJump(row.type, row.id);
      case "action":
        return props.onAction?.(row.id);
    }
  };
  const edit = (next: string) => {
    touch();
    setTouched(true);
    if (converting) {
      setText(next);
      props.onTypeAhead(next.replace(/^\s*!/, ""));
      return;
    }
    const conversion = composing.current ? undefined : terminalConversion(text, next, wholeSelection.current);
    wholeSelection.current = false;
    setText(next);
    if (conversion) {
      setConverting(true);
      if (projectCwd) props.onTerminal(conversion.command, projectCwd);
      else props.onTerminal(conversion.command);
    }
  };
  const keyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    touch();
    if (composing.current || event.nativeEvent.isComposing || converting) return;
    const input = event.currentTarget;
    wholeSelection.current =
      input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    if ((event.key === "ArrowDown" || event.key === "ArrowUp") && rows.length) {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setSelected((current) => (current + step + rows.length) % rows.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const row = rows[selected];
      if (row) activate(row);
      else if (!touched || !text.trim()) {
        const agent = orderedAgents(agents, lastAgent)[0];
        if (agent) activate({ type: "agent", harness: agent.id, name: agent.name, text: "" });
      }
    } else if (event.key === "Escape" && text) {
      event.preventDefault();
      setText("");
      setTouched(true);
    }
  };

  return (
    <div className="nt-screen" data-converting={converting || undefined}>
      {converting && (
        // R81: the terminal shows in this frame (same background, the typed command, a cursor)
        // while the daemon starts the shell; a quiet "starting" line appears after 1 s (CSS delay).
        <div className="nt-terminal" aria-label={nt("terminal")}>
          <span className="nt-terminal-command">{text.replace(/^\s*!/, "")}</span>
          <span className="nt-cursor" aria-hidden="true" />
          <span className="nt-terminal-starting">{nt("terminal")}</span>
        </div>
      )}
      {!converting && (
        <div className="nt-project">
          <ProjectChooser
            projects={projects}
            current={projectCwd}
            currentLabel={projectCwd?.split("/").filter(Boolean).pop()}
            icon={null}
            onPick={(cwd) => {
              setProjectCwd(cwd);
              field.current?.focus();
            }}
            onBrowse={
              props.onBrowseProject
                ? () => {
                    void props.onBrowseProject!()
                      .then((cwd) => {
                        if (cwd) setProjectCwd(cwd);
                        field.current?.focus();
                      })
                      .catch(() => undefined);
                  }
                : undefined
            }
          />
          {props.onImport && (
            <button type="button" onClick={props.onImport}>
              {t("empty.import")}
            </button>
          )}
        </div>
      )}
      <div className="nt-box">
        <input
          ref={field}
          className="nt-field"
          aria-label={nt("placeholder")}
          placeholder={nt("placeholder")}
          value={text}
          aria-controls="nt-rows"
          aria-activedescendant={rows.length ? `nt-row-${selected}` : undefined}
          aria-busy={converting || undefined}
          spellCheck
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
      </div>
      {rows.length > 0 && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="nt-rows" id="nt-rows" role="listbox" aria-label={nt("suggestions")}>
          {rows.map((row, index) => (
            <div
              key={rowKey(row)}
              id={`nt-row-${index}`}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === selected}
              data-type={row.type}
              className={index === selected ? "nt-row is-selected" : "nt-row"}
              onMouseMove={() => index !== selected && setSelected(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                activate(row);
              }}
            >
              {row.type === "agent" ? <AgentMark harness={row.harness} /> : <span className="nt-row-glyph" />}
              <span className="nt-row-title">{rowTitle(nt, row)}</span>
              {rowDetail(row) && <span className="nt-row-detail">{rowDetail(row)}</span>}
              <span className="nt-row-action">
                {rowAction(nt, row)}
                {index === selected && <kbd>↵</kbd>}
              </span>
            </div>
          ))}
        </div>
      )}
      {!converting && <ChatCards cards={cards} onOpen={props.onOpenSession} onShowAll={props.onShowAll} />}
    </div>
  );
}

function rowKey(row: ScreenRow): string {
  switch (row.type) {
    case "agent":
      return `agent:${row.harness}`;
    case "tab":
    case "workspace":
      return `${row.type}:${row.id}`;
    case "history":
      return `history:${row.url}`;
    case "action":
      return `action:${row.id}`;
    default:
      return row.type;
  }
}

function rowTitle(nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "agent":
      return nt("row.ask", { agent: row.name });
    case "search":
    case "open":
      return row.text;
    case "history":
      return row.title ?? row.url;
    default:
      return row.title;
  }
}

function rowDetail(row: ScreenRow): string | undefined {
  switch (row.type) {
    case "agent":
      return row.text;
    case "open":
      return row.url === row.text ? undefined : row.url;
    case "history":
      return row.title ? row.url.replace(/^https?:\/\/(www\.)?/, "") : undefined;
    case "tab":
    case "workspace":
    case "action":
      return row.detail;
    default:
      return undefined;
  }
}

function rowAction(nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "agent":
      return "";
    case "search":
      return nt("row.search");
    case "open":
      return nt("row.open");
    case "tab":
      return nt("row.tab");
    case "workspace":
      return nt("row.workspace");
    case "history":
      return nt("row.history");
    case "action":
      return nt("row.open");
  }
}
