import React, { useCallback, useEffectEvent, useLayoutEffect, useMemo, useRef, useState } from "react";
import { FOCUS_LOCATION_EVENT, FolderIcon, type NewTabHost } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { type Project, ProjectChooser } from "../ProjectChooser";
import { isAgentHome, projectLabel } from "../sessionList";
import { ChatCards } from "./ChatCards";
import { defaultModel } from "../harnessSwitch";
import { useDeviceChats } from "./deviceChats";
import {
  defaultHarness,
  initialSelection,
  recentChatCards,
  screenRows,
  shellEntry,
  stepSelection,
  type ScreenRow,
} from "./screenModel";
import { useNt } from "./strings";
import { screenSections, type ScreenTemplate } from "./templates";
import { type Translate, useT } from "../i18n";

/// What the screen asks the host to do. A prompt stays in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  /// Enter on a prompt: a chat with `harness` in `cwd` (the project picked on the page).
  onAsk(harness: string, text: string, cwd?: string): void;
  onOpen(url: string): void;
  onSearch(text: string): void;
  /// Enter in shell mode (`!` first): the page becomes a chat in its folder that runs `command`.
  onShell(command: string): void;
  onJump(target: "tab" | "workspace", id: string): void;
  onOpenSession(sessionId: string): void;
  /// A device chat card (acpmux chat index, the sidebar's All chats): the host's Open Chat path.
  onOpenChat?(key: string): void;
  onShowAll(): void;
  onRunAction?(id: string): void;
  onInputReady?(token: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
  /// Opens the host's Integrate a harness flow (`palette.addHarness`).
  onAddHarness?(): void;
};

/// The agent's model, effort and speed chip (App's composer chips), for the agent and project a
/// prompt would start in.
export type NewTabChips = React.ComponentType<{ snapshot: AcpmuxSnapshot; cwd?: string }>;

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
  /// The folder the tab inherited: the project picker starts there.
  cwd?: string;
  /// The projects the picker offers (App's newTabProjects).
  projects?: Project[];
  /// The host's folder panel; resolves with the folder picked, if any.
  onBrowseProject?(): Promise<string | undefined>;
  chips?: NewTabChips;
  /// false: the field does not take the keyboard when the screen appears (Cmd-L gave it to the
  /// omnibar); Cmd-L on the page still focuses it when the page shows no omnibar.
  focusField?: boolean;
  /// Which screen template draws the page (newtab/templates.ts); "default" when unset.
  template?: ScreenTemplate;
};

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): the project and model pickers on
/// top, then one field that reads what is typed (`!` a shell command, an address, or a prompt for
/// the picked agent, R86), the rows for addresses and open tabs only when they make sense
/// (cx-e2aa), and the recent chats as cards. A key typed anywhere on the page goes to the field.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now, tools = [], inputToken } = props;
  const template = props.template ?? "default";
  const sections = screenSections(template);
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  // The highlighted row; -1 is none (Enter is the prompt's).
  const [selected, setSelected] = useState(-1);
  /// Shell mode: the field holds a command (its `!` shown as the glyph), Enter runs it in a chat.
  const [shell, setShell] = useState(false);
  const [project, setProject] = useState(props.cwd && !isAgentHome(props.cwd) ? props.cwd : undefined);
  const field = useRef<HTMLInputElement>(null);
  const wholeSelection = useRef(false);
  const composing = useRef(false);
  const inputReported = useRef(false);
  const inputReadyReported = useRef<string | undefined>(undefined);
  const { onInputReady } = props;
  const focusOnShow = props.focusField !== false;
  const touch = () => {
    if (inputReported.current) return;
    inputReported.current = true;
    props.onTouched?.();
  };
  const agents = useMemo(
    () => snapshot.catalog.map((entry) => ({ id: entry.id, name: entry.name })),
    [snapshot.catalog],
  );
  // The agent Enter asks: the one picked on the chip (a pick draws it into the summary), else the
  // remembered one, else the first installed.
  const harness = snapshot.summary?.harness ?? defaultHarness(agents, lastAgent);
  const chipSnapshot = useMemo<AcpmuxSnapshot>(
    () =>
      snapshot.summary?.harness || !harness
        ? snapshot
        : {
            ...snapshot,
            summary: {
              ...snapshot.summary,
              sessionId: snapshot.summary?.sessionId ?? "",
              harness,
              // The agent's default model, named on the chip (its own "default" when none is known yet).
              model: defaultModel(harness, snapshot.catalog) ?? "default",
            },
          },
    [snapshot, harness],
  );
  const rows = useMemo(
    () => (touched && !shell ? screenRows(text, { omnibar, home }) : []),
    [touched, shell, text, omnibar, home],
  );
  // New tabs or pages from the host can shorten the rows under a highlight.
  const current = selected < rows.length ? selected : -1;
  const t = useT();
  const device = useDeviceChats();
  const cards = useMemo(() => recentChatCards(snapshot.sessions, now, t, device), [snapshot.sessions, now, t, device]);
  const openCard = (id: string) => {
    const key = cards.find((card) => card.sessionId === id)?.chatKey;
    if (key && props.onOpenChat) return props.onOpenChat(key);
    props.onOpenSession(id);
  };
  const list = useRef<HTMLDivElement>(null);
  // The box scrolls past its cap; the selected row stays in view. Only the box scrolls (not the
  // screen around it, as scrollIntoView would). A callback ref: it runs when a row becomes the
  // selected one.
  const keepInView = useCallback((row: HTMLElement | null) => {
    const box = list.current;
    if (!box || !row) return;
    const inner = box.getBoundingClientRect();
    const at = row.getBoundingClientRect();
    if (at.top < inner.top) box.scrollTop -= inner.top - at.top;
    else if (at.bottom > inner.bottom) box.scrollTop += at.bottom - inner.bottom;
  }, []);

  // The field takes the keyboard when the screen appears (in the commit, so an adopted spare's
  // field has focus before the next key) and on Cmd-L (FOCUS_LOCATION_EVENT).
  // Not on a parent render (the parent passes a new onInputReady each render): re-running the
  // focus selected the typed text and the next key replaced it (cx-9fl).
  const inputReady = useEffectEvent((token: string) => onInputReady?.(token));
  useLayoutEffect(() => {
    const focus = (event?: Event) => {
      field.current?.focus();
      field.current?.select();
      // The host holds keys typed since its focus request until this answer (cx-9fl).
      const token = (event as CustomEvent<{ token?: string }> | undefined)?.detail?.token;
      if (token) inputReady(token);
    };
    if (focusOnShow) focus();
    if (inputToken && inputReadyReported.current !== inputToken) {
      inputReadyReported.current = inputToken;
      inputReady(inputToken);
    }
    const view = field.current?.ownerDocument.defaultView;
    view?.addEventListener(FOCUS_LOCATION_EVENT, focus);
    return () => view?.removeEventListener(FOCUS_LOCATION_EVENT, focus);
  }, [inputToken, focusOnShow]);

  const activate = (row: ScreenRow) => {
    switch (row.type) {
      case "search":
        return props.onSearch(row.text);
      case "open":
        return props.onOpen(row.url);
      case "history":
        return props.onOpen(row.url);
      case "tab":
        return props.onJump("tab", row.id);
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
    setSelected(initialSelection(next, home));
  };
  const submit = () => {
    const row = rows[current];
    if (row) return activate(row);
    const prompt = text.trim();
    if (!prompt || initialSelection(prompt, home) === 0 || !harness) return;
    props.onAsk(harness, prompt, project);
  };
  // A key typed anywhere on the page goes into the field, the first key kept (Lawrence
  // 2026-10-09: "if i just start typing it needs to automatically start typing"). Another field
  // (a picker's search), a menu with its own keys, a chord and IME keep theirs.
  const typeAnywhere = useRef<(event: KeyboardEvent) => void>(() => undefined);
  typeAnywhere.current = (event) => {
    const input = field.current;
    if (!input || event.defaultPrevented || event.isComposing) return;
    if (event.metaKey || event.ctrlKey || event.altKey || event.key.length !== 1) return;
    const target = event.target as Element | null;
    const element = target && typeof target.closest === "function" ? target : undefined;
    if (target === input || (element && ownsKeys(element))) return;
    // Space on a focused button presses it.
    if (event.key === " " && element?.closest('button, a, summary, [role="button"]')) return;
    event.preventDefault();
    input.focus();
    // A location the page put in the field, still selected, is replaced as a typed key would.
    const whole = input.value !== "" && input.selectionStart === 0 && input.selectionEnd === input.value.length;
    wholeSelection.current = whole;
    edit(whole ? event.key : input.value + event.key);
  };
  const screen = useCallback((node: HTMLDivElement | null) => {
    const document = node?.ownerDocument;
    if (!document) return;
    const listener = (event: KeyboardEvent) => typeAnywhere.current(event);
    // ui-allow: the page's type-to-field rule needs every key that no control on the page takes.
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, []);
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
    const step = listStep(event);
    if (step && rows.length) {
      event.preventDefault();
      setSelected(stepSelection(current, step, rows.length));
    } else if (event.key === "Enter") {
      event.preventDefault();
      submit();
    } else if (event.key === "Escape" && text) {
      event.preventDefault();
      setText("");
      setSelected(-1);
      setTouched(true);
    }
  };
  const pickProject = (cwd: string) => {
    touch();
    setProject(cwd);
    field.current?.focus();
  };
  const browseProject = props.onBrowseProject
    ? () => {
        void props.onBrowseProject?.().then((cwd) => {
          if (cwd) pickProject(cwd);
        });
      }
    : undefined;
  const Chips = props.chips;
  const chatFolder = project ?? props.cwd;

  return (
    <div ref={screen} className="nt-screen" data-shell={shell || undefined} data-template={template}>
      <div className="nt-pickers" onPointerDownCapture={touch}>
        <ProjectChooser
          projects={props.projects ?? []}
          current={project}
          {...(project ? { currentLabel: projectLabel(project) } : {})}
          icon={<FolderIcon />}
          onPick={pickProject}
          {...(browseProject ? { onBrowse: browseProject } : {})}
          side="bottom"
        />
        {/* The folder Enter asks in (screenActions: the picked project, else the tab's), so a pick's
            switch is the one Enter reuses. */}
        {Chips && <Chips snapshot={chipSnapshot} {...(chatFolder ? { cwd: chatFolder } : {})} />}
      </div>
      <div className="nt-box">
        {shell ? (
          <span className="nt-shell-glyph" aria-hidden="true">
            !
          </span>
        ) : (
          sections.prompt && (
            <span className="nt-prompt-glyph" aria-hidden="true">
              &gt;
            </span>
          )
        )}
        <input
          ref={field}
          className="nt-field"
          aria-label={shell ? t("composer.shell") : nt("placeholder")}
          placeholder={shell ? t("composer.shellPlaceholder") : nt("placeholder")}
          value={text}
          aria-controls="nt-rows"
          aria-activedescendant={rows[current] ? `nt-row-${current}` : undefined}
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
              ref={index === current ? keepInView : undefined}
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="option"
              tabIndex={-1}
              aria-selected={index === current}
              data-type={row.type}
              className={index === current ? "nt-row is-selected" : "nt-row"}
              onMouseMove={() => index !== current && setSelected(index)}
              onMouseDown={(event) => {
                event.preventDefault();
                activate(row);
              }}
            >
              <span className="nt-row-glyph" data-kind={row.type}>
                {rowIcon(row)}
              </span>
              <span className="nt-row-title">{rowTitle(row)}</span>
              {rowDetail(row) && <span className="nt-row-detail">{rowDetail(row)}</span>}
              <span className="nt-row-action">
                {rowAction(t, row)}
                {index === current && <kbd>↵</kbd>}
              </span>
            </div>
          ))}
        </div>
      )}
      {sections.chats !== "none" && (
        <ChatCards cards={cards} variant={sections.chats} onOpen={openCard} onShowAll={props.onShowAll} />
      )}
      {sections.tools && props.onAddHarness && (
        <button type="button" className="nt-add-harness" onClick={() => props.onAddHarness?.()}>
          {t("newtab.addHarness")}
        </button>
      )}
      {sections.tools && <ToolsSection tools={tools} onRunAction={props.onRunAction} />}
    </div>
  );
}

/// Down or Ctrl-N is 1, Up or Ctrl-P is -1 (R85: the native list.next keys, here for a field
/// that is not a list until rows show); anything else undefined.
function listStep(event: React.KeyboardEvent): 1 | -1 | undefined {
  if (event.key === "ArrowDown") return 1;
  if (event.key === "ArrowUp") return -1;
  if (!event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return undefined;
  if (event.key === "n") return 1;
  if (event.key === "p") return -1;
  return undefined;
}

/// A control that takes typed keys itself: a text field, or a menu or list with type-ahead.
function ownsKeys(element: Element): boolean {
  if ((element as HTMLElement).isContentEditable || element.closest("input, textarea, select")) return true;
  return element.closest('[role="menu"], [role="listbox"], [role="dialog"], [role="combobox"]') !== null;
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
    case "tab":
      return `tab:${row.id}`;
    case "history":
      return `history:${row.url}`;
    default:
      return row.type;
  }
}

function rowIcon(row: ScreenRow): string {
  switch (row.type) {
    case "tab":
      return "▣";
    case "history":
      return "◷";
    case "open":
      return "↗";
    case "search":
      return "⌕";
  }
}

function rowTitle(row: ScreenRow): string {
  switch (row.type) {
    case "search":
    case "open":
      return row.text;
    case "history":
      return row.title ?? row.url;
    case "tab":
      return row.title;
  }
}

function rowDetail(row: ScreenRow): string | undefined {
  switch (row.type) {
    case "open":
      return row.url === row.text ? undefined : row.url;
    case "history":
      return row.title ? row.url.replace(/^https?:\/\/(www\.)?/, "") : undefined;
    case "tab":
      return row.detail;
    default:
      return undefined;
  }
}

function rowAction(t: Translate, row: ScreenRow): string {
  switch (row.type) {
    case "search":
    case "open":
      return t("newTabPage.row.open");
    case "tab":
      return t("newTabPage.row.tab");
    case "history":
      return t("newTabPage.row.history");
  }
}
