// New Message's To: field, as in Messages (HomeRecipientField): "To:", one token per recipient,
// then the text being typed, and a + button at the end. Typing suggests people; Return, comma or
// Tab make the text a token (the highlighted suggestion when there is one); Backspace with nothing
// typed removes the selected token, else the last one; Up and Down move through the suggestions,
// skipping headers. Before anyone is chosen and while nothing is typed, the list offers the Chiefs
// and the team in sections, with New Chief after the Chiefs, nothing highlighted until Down.
// Return with nothing typed chooses the highlighted row, else (and Tab with nothing typed) hands
// the keyboard to the message box (`onDone`). Escape closes the list, then goes to the page.
// The draft is the page's (controlled), so it stays while the person looks at another conversation.
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import type { Strings } from "../../shared/i18n";
import { Listbox } from "../../../ui/Listbox";
import { Avatar } from "../../home-channels/Avatar";
import { HomeIcon } from "../../home-channels/icons";
import type { ContactAddress } from "./address";
import {
  addRecipient,
  commitDraft,
  contactRecipient,
  deleteBackward,
  draftRecipients,
  idleRows,
  isDraftEmpty,
  isSelectable,
  recipientLabel,
  removeToken,
  sameRecipient,
  suggestionLines,
  trimSeparators,
  typedRows,
  type HomeContact,
  type HomeRecipient,
  type RecipientDraft,
  type RecipientLook,
  type SuggestionRow,
} from "./recipients";
import "./sheets.css";

/** How a token draws: a soft accent pill (Messages, the pick), an outlined pill, or plain text. */
export type TokenStyle = "pill" | "outline" | "text";

export interface RecipientFieldProps {
  strings: Strings;
  draft: RecipientDraft;
  onDraft(draft: RecipientDraft): void;
  /** Everyone the field suggests (team, connections, Chiefs). */
  contacts: readonly HomeContact[];
  /** What the list offers before anyone is chosen or typed (the Chiefs, main first, then the team). */
  idle: readonly HomeContact[];
  /** The idle list's New Chief row; absent leaves it out. */
  onNewChief?(): void;
  /** The idle list's Invite row, when the Team section has nobody; absent leaves it out. */
  onInvite?(): void;
  /** The active team's name: a typed email address gets an "Invite … to <team>" row. */
  inviteTeam?: string | null;
  onInviteToTeam?(address: ContactAddress): void;
  /** Return or Tab with nothing typed: the message box takes the keyboard. */
  onDone(): void;
  /** Escape with the list closed: the page may end the draft. */
  onEscape(): void;
  /** Where a Chief runs and when it was last active. */
  look?(recipient: HomeRecipient): RecipientLook;
  tokenStyle?: TokenStyle;
  /** The field takes the keyboard when it mounts (the page opens with the caret here). */
  focusOnMount?: boolean;
}

type Mode = "auto" | "browse" | "hidden";

const ROW = 44;
const HEADER = 26;
const MAX_ROWS = 9;

const participantOf = (recipient: HomeRecipient) =>
  recipient.kind === "contact"
    ? {
        id: recipient.contact.id,
        name: recipient.contact.name,
        kind: recipient.contact.source === "agent" ? ("agent" as const) : ("human" as const),
        chief: recipient.contact.source === "agent",
      }
    : { id: recipient.address.value, name: recipient.address.value, kind: "human" as const, chief: false };

export function RecipientField({
  strings,
  draft,
  onDraft,
  contacts,
  idle,
  onNewChief,
  onInvite,
  inviteTeam = null,
  onInviteToTeam,
  onDone,
  onEscape,
  look,
  tokenStyle = "pill",
  focusOnMount,
}: RecipientFieldProps) {
  const { t, format } = strings;
  const input = useRef<HTMLInputElement | null>(null);
  const [mode, setMode] = useState<Mode>("auto");
  const [selected, setSelected] = useState<number | null>(null);
  useEffect(() => {
    if (focusOnMount) input.current?.focus();
    // Only on mount.
    // oxlint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const listId = `hm-suggestions-${useId().replace(/:/g, "")}`;

  const rows = useMemo<SuggestionRow[]>(() => {
    if (mode === "hidden") return [];
    if (mode === "browse") {
      const chosen = draftRecipients(draft);
      return contacts
        .map(contactRecipient)
        .filter((recipient) => !chosen.some((other) => sameRecipient(other, recipient)))
        .map((recipient) => ({ kind: "recipient", recipient }));
    }
    if (isDraftEmpty(draft)) return idleRows(idle, { newChief: !!onNewChief, invite: !!onInvite }, strings);
    return typedRows(draft, contacts, onInviteToTeam ? inviteTeam : null);
  }, [mode, draft, contacts, idle, onNewChief, onInvite, inviteTeam, onInviteToTeam, strings]);
  const lines = useMemo(() => suggestionLines(rows, look ?? (() => ({})), strings), [rows, look, strings]);
  const emptyText = mode === "browse" && rows.length === 0 ? t("home.compose.noContacts") : null;
  const visible = rows.length > 0 || emptyText !== null;

  // The highlight: the first pickable row of a typed or browsed list, none in the idle list until
  // Down. A move holds until the rows change.
  const rowsKey = `${mode}\u0000${draft.query}\u0000${draft.tokens.length}\u0000${rows.length}`;
  const firstPick = mode === "browse" || !isDraftEmpty(draft) ? rows.findIndex(isSelectable) : -1;
  const [moved, setMoved] = useState<{ key: string; index: number }>({ key: "", index: -1 });
  const highlighted = moved.key === rowsKey ? moved.index : firstPick;

  const update = (next: RecipientDraft) => {
    setMode("auto");
    setSelected(null);
    onDraft(next);
  };
  const focus = () => input.current?.focus();
  const activate = (row: SuggestionRow) => {
    if (row.kind === "recipient") update(addRecipient(draft, row.recipient));
    else if (row.kind === "newChief") onNewChief?.();
    else if (row.kind === "invite") onInvite?.();
    else if (row.kind === "inviteToTeam") onInviteToTeam?.(row.address);
  };
  /** The typed text becomes a token: the highlighted suggestion, else what it parses as. With
   * `pickWithNothingTyped` (Return) the highlighted row is chosen with nothing typed. */
  const commit = (text: string, pickWithNothingTyped: boolean): boolean => {
    const typed = trimSeparators(text);
    if (!typed && !pickWithNothingTyped) return false;
    const row = highlighted >= 0 ? rows[highlighted] : undefined;
    if (row && visible) {
      activate(row);
      return true;
    }
    if (!typed) return false;
    update(commitDraft({ ...draft, query: typed }, contacts).draft);
    return true;
  };
  const move = (offset: number) => {
    const pickable = rows.flatMap((row, index) => (isSelectable(row) ? [index] : []));
    if (pickable.length === 0) return;
    const at = pickable.indexOf(highlighted);
    const next = pickable[Math.min(Math.max(at + offset, 0), pickable.length - 1)]!;
    setMoved({ key: rowsKey, index: next });
  };
  const keys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.nativeEvent.isComposing) return;
    const value = event.currentTarget.value;
    switch (event.key) {
      case "Enter":
        event.preventDefault();
        if (!commit(value, true)) onDone();
        return;
      case "Tab":
        if (event.shiftKey) return;
        event.preventDefault();
        if (!commit(value, false)) onDone();
        return;
      case "Backspace":
      case "Delete": {
        if (value !== "") return;
        if (selected !== null) {
          event.preventDefault();
          update(removeToken(draft, selected));
          return;
        }
        const next = deleteBackward({ ...draft, query: "" });
        if (next) {
          event.preventDefault();
          update(next);
        }
        return;
      }
      case "ArrowDown":
      case "ArrowUp":
        if (!visible) return;
        event.preventDefault();
        move(event.key === "ArrowDown" ? 1 : -1);
        return;
      case "Escape":
        event.preventDefault();
        event.stopPropagation();
        // The Chiefs offered before anything is typed stay: Escape goes to the page.
        if (visible && (mode === "browse" || !isDraftEmpty(draft))) setMode("hidden");
        else onEscape();
        return;
    }
  };
  const typed = (value: string) => {
    // A comma or semicolon ends the token as Messages does.
    if (value.endsWith(",") || value.endsWith(";")) {
      if (!commit(value.slice(0, -1), false)) update({ ...draft, query: "" });
      return;
    }
    update({ ...draft, query: value });
  };
  const browse = () => {
    setMode("browse");
    setSelected(null);
    focus();
  };

  const names = draft.tokens.map((token) => token.text).join(", ");
  return (
    <div className="hm-to-wrap">
      <div className="hm-to" data-token-style={tokenStyle}>
        <span className="hm-to-label">{t("home.compose.toLabel")}</span>
        {draft.tokens.map((token, index) => (
          <button
            key={`${index}:${token.text}`}
            type="button"
            tabIndex={-1}
            className="hm-token"
            data-invalid={!token.recipient || undefined}
            data-selected={selected === index || undefined}
            data-testid="cmux.home.newMessage.token"
            aria-label={format("home.compose.removeRecipient", token.text)}
            title={token.recipient ? undefined : format("home.compose.unknownRecipient", token.text)}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              setSelected(index);
              focus();
            }}
          >
            {token.text}
          </button>
        ))}
        <input
          ref={input}
          className="hm-to-input"
          value={draft.query}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-label={
            names ? `${t("home.compose.search")}, ${format("home.compose.to", names)}` : t("home.compose.search")
          }
          aria-activedescendant={highlighted >= 0 && visible ? `${listId}-${highlighted}` : undefined}
          data-testid="cmux.home.newMessage.to"
          onChange={(event) => typed(event.target.value)}
          onKeyDown={keys}
          onBlur={() => setSelected(null)}
        />
        <button
          type="button"
          className="hm-to-add"
          aria-label={t("home.compose.addRecipient")}
          title={t("home.compose.addRecipient")}
          data-testid="cmux.home.newMessage.add"
          onMouseDown={(event) => event.preventDefault()}
          onClick={browse}
        >
          <HomeIcon name="plus" size={16} />
        </button>
      </div>
      {visible && (
        <div className="hm-suggestions" data-testid="cmux.home.newMessage.suggestions">
          {emptyText !== null ? (
            <p className="hm-suggestions-empty">{emptyText}</p>
          ) : (
            <SuggestionList
              id={listId}
              rows={rows}
              lines={lines}
              highlighted={highlighted}
              strings={strings}
              label={t("home.compose.search")}
              onHighlight={(index) => setMoved({ key: rowsKey, index })}
              onPick={activate}
            />
          )}
        </div>
      )}
    </div>
  );
}

const rowHeight = (row: SuggestionRow) => (row.kind === "header" ? HEADER : ROW);

/** The rows under the field: a listbox the field drives (it keeps the caret), drawn only in the
 * scrolled window, so a team of any size costs the same to show. */
function SuggestionList({
  id,
  rows,
  lines,
  highlighted,
  strings,
  label,
  onHighlight,
  onPick,
}: {
  id: string;
  rows: readonly SuggestionRow[];
  lines: ReadonlyMap<number, string>;
  highlighted: number;
  strings: Strings;
  label: string;
  onHighlight(index: number): void;
  onPick(row: SuggestionRow): void;
}) {
  const list = useRef<HTMLDivElement | null>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const tops = useMemo(() => {
    const at = [0];
    for (const row of rows) at.push(at[at.length - 1]! + rowHeight(row));
    return at;
  }, [rows]);
  const total = tops[rows.length]!;
  const height = Math.min(total, MAX_ROWS * ROW);
  // The highlighted row stays in view as Up and Down move it.
  useLayoutEffect(() => {
    const element = list.current;
    if (!element || highlighted < 0) return;
    const top = tops[highlighted]!;
    const bottom = tops[highlighted + 1]!;
    if (top < element.scrollTop) element.scrollTop = top;
    else if (bottom > element.scrollTop + height) element.scrollTop = bottom - height;
  }, [highlighted, tops, height]);
  const overscan = 4 * ROW;
  let start = 0;
  while (start < rows.length && tops[start + 1]! < scrollTop - overscan) start++;
  let end = start;
  while (end < rows.length && tops[end]! < scrollTop + height + overscan) end++;
  return (
    <Listbox
      id={id}
      items={rows}
      listRef={list}
      className="hm-suggestions-list"
      rowClassName="hm-suggestion-row"
      label={label}
      autoFocus={false}
      activeIndex={highlighted < 0 ? -1 : highlighted}
      onActiveIndexChange={(index) => {
        if (rows[index] && isSelectable(rows[index]!)) onHighlight(index);
      }}
      getKey={(row) => String(rows.indexOf(row))}
      getItemId={(_, index) => `${id}-${index}`}
      textValue={(row) => (row.kind === "recipient" ? recipientLabel(row.recipient) : "")}
      itemAttributes={(row, index) => ({
        "aria-disabled": row.kind === "header" ? "true" : undefined,
        "aria-label":
          row.kind === "header" ? row.title : rowName(row, strings) + (lines.get(index) ? `, ${lines.get(index)}` : ""),
        "data-highlighted": index === highlighted ? "true" : undefined,
        "data-kind": row.kind === "header" ? "header" : "row",
      })}
      renderItem={(row, index) => <SuggestionRowView row={row} line={lines.get(index)} strings={strings} />}
      onOpen={onPick}
      window={{ start, end, topSpace: tops[start]!, bottomSpace: total - tops[end]! }}
      onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
    />
  );
}

function rowName(row: SuggestionRow, strings: Strings): string {
  if (row.kind === "header") return row.title;
  if (row.kind === "recipient") return recipientLabel(row.recipient);
  if (row.kind === "newChief") return strings.t("home.list.newChief");
  if (row.kind === "invite") return strings.t("home.list.invite");
  return strings.format("home.teamInvite.row", row.address.value, row.team);
}

function SuggestionRowView({ row, line, strings }: { row: SuggestionRow; line?: string; strings: Strings }) {
  if (row.kind === "header") return <span className="hm-suggestion-header">{row.title}</span>;
  const icon = row.kind === "newChief" ? "chiefAdd" : "personAdd";
  return (
    <span className="hm-suggestion">
      <span className="hm-suggestion-lead">
        {row.kind === "recipient" ? (
          <Avatar participant={participantOf(row.recipient)} size={28} />
        ) : (
          <HomeIcon name={icon} size={16} />
        )}
      </span>
      <span className="hm-suggestion-text">
        <span className="hm-suggestion-name">{rowName(row, strings)}</span>
        {line && <span className="hm-suggestion-line">{line}</span>}
      </span>
    </span>
  );
}
