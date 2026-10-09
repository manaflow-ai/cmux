import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AgentMark, FOCUS_LOCATION_EVENT, type NewTabHost } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { ChatCards } from "./ChatCards";
import { recentChatCards, screenRows, shellEntry, type ScreenRow } from "./screenModel";
import { type NewTabTranslate, useNt } from "./strings";
import { type Translate, useT } from "../i18n";

/// What the screen asks the host to do. Agent rows stay in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  onAsk(harness: string, text: string): void;
  onOpen(url: string): void;
  onSearch(text: string): void;
  /// Enter in shell mode (`!` first): the page becomes a chat in its folder that runs `command`.
  onShell(command: string): void;
  onJump(target: "tab" | "workspace", id: string): void;
  onOpenSession(sessionId: string): void;
  onShowAll(): void;
  onRunAction?(id: string): void;
  onInputReady?(token: string): void;
  onOpenFolder?(path: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
  /// Opens the host's Integrate a harness flow (`palette.addHarness`).
  onAddHarness?(): void;
};

type Props = NewTabScreenActions & {
  snapshot: AcpmuxSnapshot;
  omnibar?: OmnibarContext;
  /// The tab the page opened from (its URL or folder): in the field and selected.
  location?: string;
  lastAgent?: string;
  home?: string;
  tools?: NewTabHost["tools"];
  inputToken?: string;
  now?: number;
};

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): one field that reads what is
/// typed (`!` a shell command, an address, or a prompt with the installed agents and a web search
/// row under it; no Search/Ask mode, R86), and the recent chats as cards.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now, tools = [], inputToken } = props;
  const enrichedOmnibar = useMemo(
    () => ({
      ...omnibar,
      sessions: snapshot.sessions.map((session) => ({
        sessionId: session.sessionId,
        title: session.displayTitle ?? session.sessionId,
        harness: session.harness,
        detail: session.cwd,
      })),
    }),
    [omnibar, snapshot.sessions],
  );
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  const [selected, setSelected] = useState(0);
  /// Shell mode: the field holds a command (its `!` shown as the glyph), Enter runs it in a chat.
  const [shell, setShell] = useState(false);
  const field = useRef<HTMLInputElement>(null);
  const wholeSelection = useRef(false);
  const composing = useRef(false);
  const inputReported = useRef(false);
  const inputReadyReported = useRef<string | undefined>(undefined);
  const { onInputReady } = props;
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
    () => (touched && !shell ? screenRows(text, { agents, omnibar: enrichedOmnibar, lastAgent, home }) : []),
    [touched, shell, text, agents, enrichedOmnibar, lastAgent, home],
  );
  const t = useT();
  const cards = useMemo(() => recentChatCards(snapshot.sessions, now, t), [snapshot.sessions, now, t]);
  useEffect(() => setSelected(0), [rows]);
  const list = useRef<HTMLDivElement>(null);
  // The box scrolls past its cap; the selected row stays in view. Only the box scrolls (not the
  // screen around it, as scrollIntoView would).
  useEffect(() => {
    const box = list.current;
    const row = box?.querySelector<HTMLElement>(`#nt-row-${selected}`);
    if (!box || !row) return;
    const inner = box.getBoundingClientRect();
    const at = row.getBoundingClientRect();
    if (at.top < inner.top) box.scrollTop -= inner.top - at.top;
    else if (at.bottom > inner.bottom) box.scrollTop += at.bottom - inner.bottom;
  }, [selected, rows]);

  // The field takes the keyboard when the screen appears (in the commit, so an adopted spare's
  // field has focus before the next key) and on Cmd-L (FOCUS_LOCATION_EVENT).
  useLayoutEffect(() => {
    const focus = () => {
      field.current?.focus();
      field.current?.select();
    };
    focus();
    if (inputToken && inputReadyReported.current !== inputToken) {
      inputReadyReported.current = inputToken;
      onInputReady?.(inputToken);
    }
    const view = field.current?.ownerDocument.defaultView;
    view?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => view?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
  }, [inputToken, onInputReady]);

  const activate = (row: ScreenRow) => {
    switch (row.type) {
      case "agent":
        return props.onAsk(row.harness, row.text);
      case "search":
        return props.onSearch(row.text);
      case "open":
        return props.onOpen(row.url);
      case "history":
        return props.onOpen(row.url);
      case "tab":
      case "workspace":
        return props.onJump(row.type, row.id);
      case "session":
        return props.onOpenSession(row.id);
      case "folder":
        return props.onOpenFolder?.(row.path);
      case "command":
        return props.onShell(row.command);
      case "run":
        return props.onShell(row.text);
      case "ask":
        return props.onAsk(lastAgent ?? agents[0]?.id ?? "agent", row.text);
    }
  };
  const edit = (next: string) => {
    touch();
    setTouched(true);
    const entry = composing.current || shell ? undefined : shellEntry(text, next, wholeSelection.current);
    wholeSelection.current = false;
    if (entry) {
      setShell(true);
      setText(entry.command);
      return;
    }
    setText(next);
  };
  const keyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    touch();
    if (composing.current || event.nativeEvent.isComposing) return;
    const input = event.currentTarget;
    if (shell) {
      if (event.key === "Enter") {
        event.preventDefault();
        const command = text.trim();
        if (command) props.onShell(command);
      } else if (event.key === "Escape" || (event.key === "Backspace" && input.selectionEnd === 0)) {
        // Leaves shell mode; what was typed stays in the field.
        event.preventDefault();
        setShell(false);
      }
      return;
    }
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
    } else if (event.key === "Escape" && text) {
      event.preventDefault();
      setText("");
      setTouched(true);
    }
  };

  return (
    <div className="nt-screen" data-shell={shell || undefined}>
      <div className="nt-box">
        {shell && (
          <span className="nt-shell-glyph" aria-hidden="true">
            !
          </span>
        )}
        <input
          ref={field}
          className="nt-field"
          aria-label={shell ? t("composer.shell") : nt("placeholder")}
          placeholder={shell ? t("composer.shellPlaceholder") : nt("placeholder")}
          value={text}
          aria-controls="nt-rows"
          aria-activedescendant={rows.length ? `nt-row-${selected}` : undefined}
          spellCheck={!shell}
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
        <div ref={list} className="nt-rows" id="nt-rows" role="listbox" aria-label={nt("suggestions")}>
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
              {row.type === "agent" ? (
                <AgentMark harness={row.harness} />
              ) : (
                <span className="nt-row-glyph" data-kind={row.type}>
                  {rowIcon(row)}
                </span>
              )}
              <span className="nt-row-title">{rowTitle(nt, row)}</span>
              {rowDetail(row) && <span className="nt-row-detail">{rowDetail(row)}</span>}
              <span className="nt-row-action">
                {rowAction(t, row)}
                {index === selected && <kbd>↵</kbd>}
              </span>
            </div>
          ))}
        </div>
      )}
      <ChatCards cards={cards} onOpen={props.onOpenSession} onShowAll={props.onShowAll} />
      {props.onAddHarness && (
        <button type="button" className="nt-add-harness" onClick={() => props.onAddHarness?.()}>
          {t("newtab.addHarness")}
        </button>
      )}
      <ToolsSection tools={tools} onRunAction={props.onRunAction} />
    </div>
  );
}

function ToolsSection({
  tools,
  onRunAction,
}: {
  tools: NonNullable<NewTabHost["tools"]>;
  onRunAction?: (id: string) => void;
}) {
  const t = useT();
  if (!tools.length) return null;
  return (
    <section className="nt-tools" aria-labelledby="nt-tools-heading">
      <h2 id="nt-tools-heading">{t("newTabPage.tools")}</h2>
      <div className="nt-tools-grid">
        {tools.map((tool) => (
          <div className="nt-tool-card" key={tool.id}>
            <button type="button" className="nt-tool-main" onClick={() => onRunAction?.(tool.id)}>
              <span className="nt-tool-icon" aria-hidden="true">
                {toolIcon(tool.symbol)}
              </span>
              <span>{toolTitle(t, tool)}</span>
              {tool.shortcut && <kbd>{tool.shortcut}</kbd>}
            </button>
            {tool.menu.length > 0 && (
              <div className="nt-tool-menu">
                <button type="button" aria-label={t("newTabPage.moreOptions")}>
                  …
                </button>
                <div className="nt-tool-menu-popover">
                  {tool.menu.map((id) => (
                    <button type="button" key={id} onClick={() => onRunAction?.(id)}>
                      {toolMenuTitle(t, id)}
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}

function toolIcon(symbol: string): string {
  return { plusminus: "±", terminal: "›_", folder: "▱", "bubble.left.and.text.bubble.right": "◌" }[symbol] ?? "•";
}

function toolMenuTitle(t: Translate, id: string): string {
  if (id === "splitRight") return t("newTabPage.tool.splitRight");
  if (id === "splitDown") return t("newTabPage.tool.splitDown");
  return id;
}

function toolTitle(t: ReturnType<typeof useT>, tool: NonNullable<NewTabHost["tools"]>[number]): string {
  const key: Record<
    string,
    "newTabPage.tool.changes" | "newTabPage.tool.terminal" | "newTabPage.tool.files" | "newTabPage.tool.sideChat"
  > = {
    openDiffViewer: "newTabPage.tool.changes",
    newSurface: "newTabPage.tool.terminal",
    "file.open": "newTabPage.tool.files",
    "agentPane.searchChats": "newTabPage.tool.sideChat",
  };
  return key[tool.id] ? t(key[tool.id]) : tool.title;
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
    case "session":
      return `session:${row.id}`;
    case "folder":
      return `folder:${row.path}`;
    case "command":
      return `command:${row.command}`;
    case "run":
    case "ask":
      return `${row.type}:${row.text}`;
    default:
      return row.type;
  }
}

function rowIcon(row: ScreenRow): string {
  switch (row.type) {
    case "tab":
      return "▣";
    case "workspace":
      return "▦";
    case "session":
      return "◌";
    case "folder":
      return "▱";
    case "command":
    case "run":
      return "›_";
    case "history":
      return "◷";
    case "open":
      return "↗";
    case "search":
      return "⌕";
    case "ask":
      return "✦";
    default:
      return "•";
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
    case "session":
    case "workspace":
    case "tab":
      return row.title;
    case "folder":
      return row.path;
    case "command":
      return row.command;
    case "run":
    case "ask":
      return row.text;
    default:
      return "";
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
    case "session":
      return row.detail;
    case "folder":
    case "command":
      return undefined;
    default:
      return undefined;
  }
}

function rowAction(t: Translate, row: ScreenRow): string {
  switch (row.type) {
    case "agent":
      return "";
    case "search":
      return t("newTabPage.row.open");
    case "open":
      return t("newTabPage.row.open");
    case "tab":
      return t("newTabPage.row.tab");
    case "workspace":
      return t("newTabPage.row.workspace");
    case "history":
      return t("newTabPage.row.history");
    case "session":
      return t("newTabPage.row.session");
    case "folder":
      return t("newTabPage.row.folder");
    case "command":
      return t("newTabPage.row.command");
    case "run":
      return t("newTabPage.row.run");
    case "ask":
      return t("newTabPage.ask", { agent: "agent" });
  }
}
