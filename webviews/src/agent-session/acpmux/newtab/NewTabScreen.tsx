import React, { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import type { DictationField } from "../dictation";
import { FOCUS_LOCATION_EVENT, FolderIcon, type NewTabHost } from "../NewTabPage";
import type { AcpmuxSnapshot } from "../model";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../omnibar";
import { type Project, ProjectChooser } from "../ProjectChooser";
import { isAgentHome, projectLabel } from "../sessionList";
import { AllChatsList, type LoadChatsPage } from "./AllChatsList";
import { ChatCards } from "./ChatCards";
import { ClosedList } from "./ClosedList";
import { OpenTabsList } from "./OpenTabsList";
import { ArrowUpIcon } from "../ComposerPickers";
import { newTabStart } from "./chipDefaults";
import { useLastPick } from "../lastPick";
import { useDeviceChats } from "./deviceChats";
import { useRecentlyClosed } from "./recentlyClosed";
import {
  defaultSelection,
  isAddress,
  recentChatCards,
  screenRows,
  shellEntry,
  stepSelection,
  type ScreenRow,
} from "./screenModel";
import { RowGlyph } from "./RowGlyph";
import { type NewTabTranslate, useNt } from "./strings";
import { screenSections, type ScreenTemplate } from "./templates";
import { type Translate, useT } from "../i18n";
import { ChromeArea } from "../../../ui/HideableChrome";
import { Popover } from "../../../ui/Popover";
import { useComposerChrome } from "../composerChrome";

/// What the screen asks the host to do. A prompt stays in the page (the tab becomes the chat).
export type NewTabScreenActions = {
  /// Enter on a prompt: a chat with `harness` in `cwd` (the project picked on the page).
  onAsk(harness: string, text: string, cwd?: string): void;
  onOpen(url: string): void;
  onSearch(text: string): void;
  /// Enter in shell mode (`!` first): the page becomes a chat in its folder that runs `command`.
  onShell(command: string): void;
  /// `here`: an Open Tabs pick, moved into this page's pane (cx-jfo7).
  onJump(target: "tab" | "workspace" | "here" | "closed", id: string): void;
  onOpenSession(sessionId: string): void;
  /// A device chat card (acpmux chat index, the sidebar's All chats): the host's Open Chat path.
  onOpenChat?(key: string): void;
  /// Open in terminal from an All chats row's right-click menu.
  onOpenChatInTerminal?(key: string): void;
  /// One page of All chats from the host (`chats.page`); without it the page shows no All chats list.
  loadChatsPage?: LoadChatsPage;
  onShowAll(): void;
  onInputReady?(token: string): void;
  /// The first user input reached the page (the host recycles only an untouched page, R81).
  onTouched?(): void;
  /// No agent to ask: opens the Harnesses page (cx-uj5g8).
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
  /// The workspace's tabs to move here (a split's page, cx-jfo7).
  openTabs?: NewTabHost["openTabs"];
  inputToken?: string;
  now?: number;
  /// The folder the tab inherited: the project picker starts there.
  cwd?: string;
  /// The folder a prompt with no pick starts in (the host's start folder, a private folder in a
  /// fresh workspace); the composer chip names it, not the inherited `cwd` (nxdog91 F0).
  startCwd?: string;
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
  /// Buttons before Send, such as the dictation mic (DictationMic).
  accessory?: React.ReactNode;
  /// Why dictation did not run (DictationNotice), under the field.
  notice?: React.ReactNode;
  /// Where the page's dictation writes: the field, while the screen shows.
  dictationField?: React.MutableRefObject<DictationField | null>;
};

/// The new tab screen, variant B (plans/cmux-next/new-tab.md): the project and model pickers on
/// top, then one field that reads what is typed (`!` a shell command, an address, or a prompt for
/// the picked agent, R86), the rows for addresses and open tabs only when they make sense
/// (cx-e2aa), and the recent chats as cards. A key typed anywhere on the page goes to the field.
export function NewTabScreen(props: Props) {
  const nt = useNt();
  const { snapshot, omnibar = EMPTY_OMNIBAR, location, lastAgent, home, now, inputToken } = props;
  const template = props.template ?? "default";
  const sections = screenSections(template);
  const [text, setText] = useState(location ?? "");
  // The location stays a suggestion until edited: no rows for it.
  const [touched, setTouched] = useState(false);
  // The highlighted row; -1 is none (Enter is the prompt's).
  const [selected, setSelected] = useState<number | undefined>(undefined);
  /// Shell mode: the field holds a command (its `!` shown as the glyph), Enter runs it in a chat.
  const [shell, setShell] = useState(false);
  /// Return asked with no agent to ask: the note under the field says so until the next edit.
  const [noAgent, setNoAgent] = useState(false);
  const [project, setProject] = useState(props.cwd && !isAgentHome(props.cwd) ? props.cwd : undefined);
  const field = useRef<HTMLInputElement>(null);
  const wholeSelection = useRef(false);
  const composing = useRef(false);
  const inputReported = useRef(false);
  const inputReadyReported = useRef<string | undefined>(undefined);
  // The App hands a new callback on each render; the field must not take the keyboard again for it.
  const onInputReady = useRef(props.onInputReady);
  onInputReady.current = props.onInputReady;
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
  // A real pick names its folder; else the folder the chat really starts in (screenActions onAsk).
  const chatFolder = project && project !== props.cwd ? project : (props.startCwd ?? project ?? props.cwd);
  // The agent Enter asks and the chip's model (newTabStart): the chip's pick, else the last pick.
  const remembered = useLastPick(chatFolder);
  const { harness, snapshot: chipSnapshot } = useMemo(
    () => newTabStart(snapshot, agents, lastAgent, chatFolder, remembered),
    [snapshot, agents, lastAgent, chatFolder, remembered],
  );
  // The Ask row names the agent Return asks and the model on its chip.
  const ask = useMemo(() => {
    const entry = snapshot.catalog.find((agent) => agent.id === harness);
    if (!harness || !entry) return undefined;
    const model = entry.models.find((option) => option.id === chipSnapshot.summary?.model)?.name;
    return { harness, agent: entry.name, ...(model ? { model } : {}) };
  }, [snapshot.catalog, harness, chipSnapshot.summary?.model]);
  const rows = useMemo(
    () => (touched && !shell ? screenRows(text, { omnibar, home, ...(ask ? { ask } : {}) }) : []),
    [touched, shell, text, omnibar, home, ask],
  );
  // New tabs or pages from the host can shorten the rows under a highlight.
  const current = selected === undefined ? defaultSelection(rows) : selected < rows.length ? selected : -1;
  const t = useT();
  const chrome = useComposerChrome();
  const device = useDeviceChats();
  const closed = useRecentlyClosed();
  const cards = useMemo(
    () => recentChatCards(snapshot.sessions, now, t, device, sections.recent),
    [snapshot.sessions, now, t, device, sections.recent],
  );
  // With All chats on the page (the host answers `chats.page`) every chat is in that list, so
  // the cards keep only the chats that are running or need the user.
  const allChats = sections.allChats && !!props.loadChatsPage && !!props.onOpenChat;
  const activeCards = useMemo(() => cards.filter((card) => card.state !== "idle"), [cards]);
  const openCard = (id: string) => {
    const key = cards.find((card) => card.sessionId === id)?.chatKey;
    if (key && props.onOpenChat) return props.onOpenChat(key);
    props.onOpenSession(id);
  };
  // A card's Open in Terminal, by its chat's key, as All chats opens one (only cards with a key offer it).
  const openCardInTerminal = (id: string) => {
    const key = cards.find((card) => card.sessionId === id)?.chatKey;
    if (key) props.onOpenChatInTerminal?.(key);
  };
  const list = useRef<HTMLDivElement>(null);
  // The suggestions' popover (Leo 2026-10-12) hangs under the composer box, on the popup layer:
  // it floats over every section, never covered and never moving the page.
  const [box, setBox] = useState<HTMLDivElement | null>(null);
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
  // field has focus before the next key) and on Cmd-L (FOCUS_LOCATION_EVENT); only then, so an
  // update or a click into the field never moves its caret or restarts its blink.
  useLayoutEffect(() => {
    const focus = () => {
      field.current?.focus();
      field.current?.select();
    };
    if (focusOnShow) focus();
    if (inputToken && inputReadyReported.current !== inputToken) {
      inputReadyReported.current = inputToken;
      onInputReady.current?.(inputToken);
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
      case "workspace":
        return props.onJump("workspace", row.id);
      case "ask":
        return props.onAsk(row.harness, row.text, project);
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
    setSelected(undefined);
    setNoAgent(false);
  };
  const submit = () => {
    const row = rows[current];
    if (row) return activate(row);
    const prompt = text.trim();
    if (!prompt || isAddress(prompt, home)) return;
    if (!harness) return setNoAgent(true);
    props.onAsk(harness, prompt, project);
  };
  const send = () => {
    touch();
    if (!shell) return submit();
    const command = text.trim();
    if (command) props.onShell(command);
  };
  const sendRef = useRef(send);
  sendRef.current = send;
  const editRef = useRef(edit);
  editRef.current = edit;
  const { dictationField } = props;
  useLayoutEffect(() => {
    if (!dictationField) return undefined;
    dictationField.current = {
      focus: () => field.current?.focus(),
      focused: () => document.activeElement === field.current,
      element: () => field.current,
      text: () => {
        const input = field.current;
        const value = input?.value ?? "";
        return {
          value,
          selectionStart: input?.selectionStart ?? value.length,
          selectionEnd: input?.selectionEnd ?? value.length,
        };
      },
      // Dictation splices its words in as typing would, committed at once: its next update reads
      // the field back, and auto-send sends what it holds.
      writeText: (value, selectionStart, selectionEnd) => {
        flushSync(() => editRef.current(value));
        field.current?.setSelectionRange(selectionStart, selectionEnd);
      },
      submit: () => sendRef.current(),
    };
    return () => {
      dictationField.current = null;
    };
  }, [dictationField]);
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
      setSelected(undefined);
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
  return (
    <div
      ref={screen}
      className="nt-screen"
      data-shell={shell || undefined}
      data-template={template}
      data-all-chats={allChats || undefined}
    >
      {/* One box (board 008): the field on top, the folder and the agent's model chips on its bottom
          row, the Send button at the end. */}
      <div ref={setBox} className="nt-box">
        <div className="nt-input">
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
            data-focus-ring="none"
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
        {/* The button row: a right-click here shows the mic hidden from its own (composerChrome.tsx);
            this page draws no context ring. */}
        <ChromeArea className="acpmux-chrome-area" items={[chrome.dictation]}>
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
            {props.accessory}
            {/* Send: a click does what Return does (a prompt, a row, or a shell command). */}
            <button
              type="button"
              className={text.trim() ? "acpmux-send acpmux-send-ready nt-send" : "acpmux-send nt-send"}
              aria-label={t("composer.send")}
              title={t("composer.sendTooltip")}
              disabled={!text.trim()}
              onClick={send}
            >
              <ArrowUpIcon />
            </button>
          </div>
        </ChromeArea>
      </div>
      {rows.length > 0 && box && (
        <Popover
          open
          // The rows follow the field (Escape there clears it): the popover never closes itself.
          onOpenChange={() => undefined}
          anchor={box}
          label={nt("suggestions")}
          className="nt-popover"
          initialFocus={false}
          finalFocus={false}
        >
          {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
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
                {rowFavicon(row) ? (
                  <img className="nt-row-glyph nt-row-favicon" src={rowFavicon(row)} alt="" draggable={false} />
                ) : (
                  <RowGlyph kind={row.type} />
                )}
                <span className="nt-row-title">{rowTitle(nt, row)}</span>
                {rowDetail(row) && <span className="nt-row-detail">{rowDetail(row)}</span>}
                <span className="nt-row-action">
                  {rowAction(t, nt, row)}
                  {index === current && <kbd>↵</kbd>}
                </span>
              </div>
            ))}
          </div>
        </Popover>
      )}
      {props.notice}
      {noAgent && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="nt-no-agent" role="status">
          <span>{t("newtab.noAgent")}</span>
          {props.onAddHarness && (
            <button type="button" className="nt-tool nt-add-harness ui-ghost" onClick={() => props.onAddHarness?.()}>
              <span className="nt-tool-icon ui-ghost-icon" aria-hidden="true">
                <PlusIcon />
              </span>
              <span>{t("newtab.addHarness")}</span>
            </button>
          )}
        </div>
      )}
      {props.openTabs && <OpenTabsList tabs={props.openTabs} onMoveHere={(id) => props.onJump("here", id)} />}
      {sections.closed && <ClosedList items={closed} onReopen={(id) => props.onJump("closed", id)} />}
      {sections.chats !== "none" && !allChats && (
        <ChatCards
          cards={cards}
          variant={sections.chats}
          onOpen={openCard}
          {...(props.onOpenChatInTerminal ? { onOpenInTerminal: openCardInTerminal } : {})}
          onShowAll={props.onShowAll}
        />
      )}
      {allChats && props.loadChatsPage && props.onOpenChat && (
        <AllChatsList
          load={props.loadChatsPage}
          onOpen={props.onOpenChat}
          active={activeCards.map((card) => ({
            id: card.sessionId,
            title: card.title,
            ...(card.harness ? { harness: card.harness } : {}),
            state: card.state,
            label: nt(`card.${card.state as "input" | "running" | "error" | "unread"}`),
          }))}
          onOpenActive={openCard}
          {...(props.onOpenChatInTerminal ? { onOpenInTerminal: props.onOpenChatInTerminal } : {})}
          {...(now !== undefined ? { now } : {})}
        />
      )}
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

/// The 14 px plus in currentColor before "Integrate a harness".
function PlusIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M8 3v10M3 8h10" />
    </svg>
  );
}

function rowKey(row: ScreenRow): string {
  switch (row.type) {
    case "tab":
      return `tab:${row.id}`;
    case "history":
      return `history:${row.url}`;
    case "open":
      return `open:${row.url}`;
    case "workspace":
      return `workspace:${row.id}`;
    default:
      return row.type;
  }
}

/// A tab's or visited page's favicon (cx-d0d.8): it takes the glyph's place when the host sent one.
function rowFavicon(row: ScreenRow): string | undefined {
  return row.type === "tab" || row.type === "history" ? row.icon : undefined;
}

function rowTitle(nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "search":
      return nt("row.searchFor", { text: row.text });
    case "ask":
      return nt("row.ask", { agent: row.agent });
    case "open":
      return row.text;
    case "history":
      return row.title ?? row.url;
    case "tab":
    case "workspace":
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
    case "workspace":
      return row.detail;
    case "ask":
      return row.model;
    default:
      return undefined;
  }
}

function rowAction(t: Translate, nt: NewTabTranslate, row: ScreenRow): string {
  switch (row.type) {
    case "search":
    case "open":
      return t("newTabPage.row.open");
    case "ask":
      return t("composer.send");
    case "workspace":
      return nt("row.workspace");
    case "tab":
      return t("newTabPage.row.tab");
    case "history":
      return t("newTabPage.row.history");
  }
}
