// The Passwords page (plans/cmux-next/passwords.md 1.4). State lives in `PasswordsStore`; this
// file renders it and turns clicks and form submits into store intents. It never shows a password:
// Show and Copy ask the app, which authenticates the person and uses a native sheet or the
// pasteboard. Keys belong to the app's key dispatcher; the page handles none itself.
// Each section's list is windowed: only the rows near the viewport are mounted, plus the focused
// row and the one whose username is being edited. Rows are memoized on their row and offset with
// stable handlers, so a focus, a scroll step or a reply that changes one row draws only that row.
import {
  memo,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type FocusEvent,
  type FormEvent,
  type ReactNode,
} from "react";
import { defaultRangeExtractor, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { useStableHandlers } from "../../agent-session/acpmux/stableHandlers";
import type { Strings } from "../shared/i18n";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../ui/lasting";
import {
  filterExceptions,
  filterPasskeys,
  filterPasswords,
  groupBySite,
  type LoginItem,
  loginList,
  rowList,
  siteInitial,
  sortExceptions,
  sortPasskeys,
  type SortMode,
  type Windowed,
} from "./model";
import type { PasswordsStore } from "./store";
import type { PasswordException, SavedPasskey, SavedPassword } from "./types";
import { intl } from "../../ui/intl";

/** Item heights before the first of their kind is measured (styles.css): a site's header carries its
 *  group's 4 px above, its last login the 4 px below. */
const ESTIMATES = { site: 32, login: 30, "login-end": 34, passkey: 30, exception: 30 } as const;
type SizeKind = keyof typeof ESTIMATES;
/** About one viewport of rows above and below the visible ones. */
const OVERSCAN = 20;

const dateFormats = new Map<string, Intl.DateTimeFormat>();
function dateFormat(language: string): Intl.DateTimeFormat {
  let format = dateFormats.get(language);
  if (!format) dateFormats.set(language, (format = intl.DateTimeFormat(language, { dateStyle: "medium" })));
  return format;
}

const focusOnMount = (node: HTMLInputElement | null) => node?.focus();
const editOnMount = (node: HTMLInputElement | null) => {
  if (!node) return;
  node.focus();
  node.select();
};

const ICONS = {
  // Eye.
  reveal:
    "M1.75 8S4.25 3.5 8 3.5 14.25 8 14.25 8 11.75 12.5 8 12.5 1.75 8 1.75 8ZM8 6.25a1.75 1.75 0 1 0 0 3.5 1.75 1.75 0 0 0 0-3.5Z",
  // Two sheets.
  copy: "M5.5 5.5h7v8h-7ZM3.5 10.5v-8h7",
  // Pencil.
  edit: "M10.75 2.75 13.25 5.25 5.5 13H3v-2.5ZM9 4.5l2.5 2.5",
  // Trash.
  delete: "M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.75 9h5.5l.75-9",
  // Cross.
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
};

function Icon({ name }: { name: keyof typeof ICONS }) {
  return (
    <svg className="pw-icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={ICONS[name]}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function RowButton({ icon, label, onClick }: { icon: keyof typeof ICONS; label: string; onClick: () => void }) {
  return (
    <button type="button" className="pw-row-button" aria-label={label} title={label} onClick={onClick}>
      <Icon name={icon} />
    </button>
  );
}

function Unavailable({ text }: { text: string }) {
  return <p className="pw-unavailable">{text}</p>;
}

export function PasswordsPage({ store, strings }: { store: PasswordsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const disconnected = snap.connection === "disconnected";
  // A lost link keeps the list on screen and says so only once it lasts (ui/lasting.ts): a daemon
  // restart drops it for a few seconds, and the person has nothing to do (Leo, 2026-11-14).
  const downLasting = useConnectionQuiet(disconnected);
  const logins = useMemo(
    () => loginList(groupBySite(filterPasswords(snap.passwords, snap.text), snap.sort)),
    [snap.passwords, snap.text, snap.sort],
  );
  const passkeys = useMemo(
    () => rowList(sortPasskeys(filterPasskeys(snap.passkeys, snap.text)), "passkey"),
    [snap.passkeys, snap.text],
  );
  const exceptions = useMemo(
    () => rowList(sortExceptions(filterExceptions(snap.exceptions, snap.text)), "exception"),
    [snap.exceptions, snap.text],
  );
  const searching = snap.text.trim().length > 0;
  const [scroller, setScroller] = useState<HTMLDivElement | null>(null);
  // The row that holds focus stays mounted however far the list scrolls (its key: `login:<id>`).
  const [focused, setFocused] = useState<string | undefined>(undefined);
  const onFocus = (event: FocusEvent) =>
    setFocused((event.target as HTMLElement).closest<HTMLElement>("[data-key]")?.dataset.key);
  const onBlur = (event: FocusEvent<HTMLElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setFocused(undefined);
  };

  const empty = (key: string) => <p className="pw-empty">{searching ? t("passwords.page.noMatches") : t(key)}</p>;

  // One function per handler for every render: a memo row draws again only when its own props change.
  const handlers = useStableHandlers({
    onReveal: (row: SavedPassword) => void store.reveal(row),
    onCopy: (row: SavedPassword) => void store.copy(row),
    onEdit: (row: SavedPassword) => store.editUsername(row),
    onDelete: (row: SavedPassword) => void store.removePassword(row),
    onCommit: (row: SavedPassword, username: string) => void store.commitUsername(row, username),
    onCancel: () => store.cancelEdit(),
    onRemovePasskey: (row: SavedPasskey) => void store.removePasskey(row),
    onRemoveException: (row: PasswordException) => void store.removeException(row),
  });
  const kept = (list: Windowed<unknown>, ...keys: (string | undefined)[]) =>
    keys.flatMap((key) => {
      const index = key === undefined ? undefined : list.place.get(key);
      return index === undefined ? [] : [index];
    });

  const notice = snap.notice && (
    <output className={`pw-notice ${snap.notice.kind}`}>
      <span>
        {snap.notice.kind === "copied"
          ? t("passwords.page.copied")
          : snap.notice.kind === "exported"
            ? t("passwords.page.exported")
            : strings.format("passwords.page.failed", snap.notice.message)}
      </span>
      <button
        type="button"
        className="pw-row-button"
        aria-label={t("passwords.page.cancel")}
        onClick={() => store.dismissNotice()}
      >
        <Icon name="close" />
      </button>
    </output>
  );

  return (
    <div className="pw-page">
      <header className="pw-header" data-titlebar>
        <div className="pw-title-row">
          <h1 className="pw-title">{t("passwords.page.title")}</h1>
          {snap.profiles.length > 1 && (
            <select
              className="pw-select pw-profile"
              aria-label={t("passwords.page.profile")}
              value={snap.profile}
              onChange={(event) => store.setProfile(event.currentTarget.value)}
            >
              {snap.profiles.map((profile) => (
                <option key={profile.id} value={profile.id}>
                  {profile.name}
                </option>
              ))}
            </select>
          )}
          {snap.sections.browserImport && (
            <button
              type="button"
              className="pw-button pw-import-browser"
              disabled={disconnected}
              onClick={() => void store.importFromBrowser()}
            >
              {t("passwords.page.importBrowser")}
            </button>
          )}
          <button
            type="button"
            className="pw-button pw-import-files"
            disabled={disconnected}
            onClick={() => void store.importFromFiles()}
          >
            {t("passwords.page.importFiles")}
          </button>
          <button
            type="button"
            className="pw-button pw-export"
            disabled={!snap.sections.export || snap.sections.exportOff === true || disconnected}
            // tooltip-allow: why the button is disabled
            title={
              !snap.sections.export
                ? t("passwords.page.availableAfterUpdate")
                : snap.sections.exportOff
                  ? t("passwords.page.exportOff")
                  : undefined
            }
            onClick={() => void store.exportAll()}
          >
            {t("passwords.page.export")}
          </button>
        </div>
        <div className="pw-search-row">
          <input
            ref={focusOnMount}
            className="pw-search"
            type="search"
            placeholder={t("passwords.page.search")}
            aria-label={t("passwords.page.search")}
            value={snap.text}
            onChange={(event) => store.setText(event.currentTarget.value)}
          />
          <select
            className="pw-select"
            aria-label={t("passwords.page.sort")}
            value={snap.sort}
            disabled={!snap.sections.passwords}
            onChange={(event) => store.setSort(event.currentTarget.value as SortMode)}
          >
            <option value="site">{t("passwords.page.sort.site")}</option>
            <option value="recent">{t("passwords.page.sort.recent")}</option>
            <option value="mostUsed">{t("passwords.page.sort.mostUsed")}</option>
          </select>
        </div>
      </header>
      {notice}
      <div ref={setScroller} className="pw-scroll" onFocus={onFocus} onBlur={onBlur}>
        {/* The rows stay while the link is down; a corner mark says so once it lasts (ui/ConnectionChip.tsx). */}
        {downLasting ? <ConnectionChip text={t("passwords.page.disconnected")} /> : null}
        {snap.loading ? (
          <p className="pw-empty">{t("passwords.page.loading")}</p>
        ) : disconnected && !snap.passwords.length && !snap.passkeys.length && !snap.exceptions.length ? (
          // Nothing read yet and the link is down: nothing to draw, and no false "No passwords" either.
          <p className="pw-empty" />
        ) : (
          <>
            <section className="pw-section" aria-labelledby="pw-passwords">
              <h2 id="pw-passwords" className="pw-section-title">
                {t("passwords.page.section.passwords")}
              </h2>
              {!snap.sections.passwords ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : logins.items.length === 0 ? (
                empty("passwords.page.empty.passwords")
              ) : (
                <WindowedList
                  scroller={scroller}
                  list={logins}
                  size={loginSize}
                  // The focused row, and the row whose username is being edited (its field has focus and
                  // what was typed), stay mounted.
                  kept={kept(logins, focused, snap.editing === undefined ? undefined : `login:${snap.editing}`)}
                  item={(index, top, measure) => {
                    const item = logins.items[index]!;
                    return item.kind === "site" ? (
                      <SiteHeader key={logins.keys[index]} index={index} top={top} measure={measure} site={item.site} />
                    ) : (
                      <LoginRow
                        key={logins.keys[index]}
                        index={index}
                        top={top}
                        measure={measure}
                        row={item.row}
                        site={item.site}
                        last={item.last}
                        position={item.position}
                        setSize={logins.rows}
                        editing={snap.editing === item.row.id}
                        strings={strings}
                        onReveal={handlers.onReveal}
                        onCopy={handlers.onCopy}
                        onEdit={handlers.onEdit}
                        onDelete={handlers.onDelete}
                        onCommit={handlers.onCommit}
                        onCancel={handlers.onCancel}
                      />
                    );
                  }}
                />
              )}
            </section>
            <section className="pw-section" aria-labelledby="pw-passkeys">
              <h2 id="pw-passkeys" className="pw-section-title">
                {t("passwords.page.section.passkeys")}
              </h2>
              <p className="pw-help">{t("passwords.page.passkeysHelp")}</p>
              {!snap.sections.passkeys ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : passkeys.items.length === 0 ? (
                empty("passwords.page.empty.passkeys")
              ) : (
                <WindowedList
                  scroller={scroller}
                  list={passkeys}
                  size={passkeySize}
                  kept={kept(passkeys, focused)}
                  item={(index, top, measure) => (
                    <PasskeyRow
                      key={passkeys.keys[index]}
                      index={index}
                      top={top}
                      measure={measure}
                      row={passkeys.items[index]!}
                      setSize={passkeys.rows}
                      strings={strings}
                      onRemove={handlers.onRemovePasskey}
                    />
                  )}
                />
              )}
            </section>
            <section className="pw-section" aria-labelledby="pw-exceptions">
              <h2 id="pw-exceptions" className="pw-section-title">
                {t("passwords.page.section.exceptions")}
              </h2>
              <p className="pw-help">{t("passwords.page.exceptionsHelp")}</p>
              {!snap.sections.exceptions ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : exceptions.items.length === 0 ? (
                empty("passwords.page.empty.exceptions")
              ) : (
                <WindowedList
                  scroller={scroller}
                  list={exceptions}
                  size={exceptionSize}
                  kept={kept(exceptions, focused)}
                  item={(index, top, measure) => (
                    <ExceptionRow
                      key={exceptions.keys[index]}
                      index={index}
                      top={top}
                      measure={measure}
                      row={exceptions.items[index]!}
                      setSize={exceptions.rows}
                      strings={strings}
                      onRemove={handlers.onRemoveException}
                    />
                  )}
                />
              )}
            </section>
          </>
        )}
      </div>
    </div>
  );
}

const loginSize = (item: LoginItem): SizeKind => (item.kind === "site" ? "site" : item.last ? "login-end" : "login");
const passkeySize = (): SizeKind => "passkey";
const exceptionSize = (): SizeKind => "exception";

interface WindowedListProps<T> {
  /** The page's scroller: every section's list scrolls in it, each from its own offset. */
  scroller: HTMLElement | null;
  list: Windowed<T>;
  size: (item: T) => SizeKind;
  /** Items that stay mounted wherever the list scrolls. */
  kept: number[];
  item: (index: number, top: number, measure: (element: HTMLElement | null) => void) => ReactNode;
}

/** One section's list, windowed in the page's scroller: the items near the viewport, about one
 *  viewport each side, and the kept ones. */
function WindowedList<T>({ scroller, list, size, kept, item }: WindowedListProps<T>) {
  const space = useRef<HTMLDivElement | null>(null);
  // Where the list starts in the scroller's content: below the sections and the lists above it.
  // Read once it mounts and again when a section resizes, never on a scroll.
  const [margin, setMargin] = useState(0);
  useLayoutEffect(() => {
    if (!scroller) return;
    const update = () => setMargin(space.current?.offsetTop ?? 0);
    update();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(update);
    for (const section of scroller.children) observer.observe(section);
    return () => observer.disconnect();
  }, [scroller]);
  // One function per list: TanStack measures every item again when it changes.
  const itemKey = useCallback((index: number) => list.keys[index]!, [list]);
  // The first mounted item of each kind sizes every one not yet mounted, so the rows a scroll brings
  // in measure as estimated: TanStack places all N items again whenever a measure differs.
  const sizes = useRef(new Map<SizeKind, number>());
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so each passwords section list stays uncompiled on purpose; it needs a stable getItemKey (so one changed login does not re-measure all N items) and keeps two rows mounted (the focused one and the login being edited), and ui/VirtualList keys items by index and keeps only one active row, so ui/VirtualList does not fit.
  const virtualizer = useVirtualizer({
    count: list.items.length,
    getScrollElement: () => scroller,
    estimateSize: (index) => {
      const kind = size(list.items[index]!);
      return sizes.current.get(kind) ?? ESTIMATES[kind];
    },
    getItemKey: itemKey,
    overscan: OVERSCAN,
    scrollMargin: margin,
    rangeExtractor: (range: Range) => {
      const indexes = defaultRangeExtractor(range);
      for (const index of kept)
        if (!indexes.includes(index)) {
          indexes.push(index);
          indexes.sort((a, b) => a - b);
        }
      return indexes;
    },
  });
  const measure = useCallback(
    (node: HTMLElement | null) => {
      const kind = node?.dataset.size as SizeKind | undefined;
      if (node && kind && !sizes.current.has(kind) && node.offsetHeight > 0) sizes.current.set(kind, node.offsetHeight);
      virtualizer.measureElement(node);
    },
    [virtualizer],
  );
  return (
    <div
      ref={space}
      className="pw-list"
      // A list of absolutely placed items: a site's header is not a list item, so no `ul`.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="list"
      style={{ height: virtualizer.getTotalSize() }}
    >
      {virtualizer.getVirtualItems().map(({ index, start }) => item(index, start - margin, measure))}
    </div>
  );
}

/** Where a windowed item sits: its index (TanStack measures it by `data-index`) and offset. */
interface Placed {
  index: number;
  top: number;
  measure: (element: HTMLElement | null) => void;
}

const SiteHeader = memo(function SiteHeader({ index, top, measure, site }: Placed & { site: string }) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="site"
      data-key={`site:${site}`}
      className="pw-site pw-site-head"
      data-site={site}
      style={{ transform: `translateY(${top}px)` }}
    >
      <div className="pw-site-header">
        <span className="pw-site-badge" aria-hidden="true">
          {siteInitial(site)}
        </span>
        <span className="pw-site-name">{site}</span>
      </div>
    </div>
  );
});

interface LoginRowProps extends Placed {
  row: SavedPassword;
  site: string;
  /** The site's last login: it carries the group's space below. */
  last: boolean;
  /** 1-based place among every shown login, and their count: the screen reader's "3 of 1000". */
  position: number;
  setSize: number;
  editing: boolean;
  strings: Strings;
  onReveal: (row: SavedPassword) => void;
  onCopy: (row: SavedPassword) => void;
  onEdit: (row: SavedPassword) => void;
  onDelete: (row: SavedPassword) => void;
  onCommit: (row: SavedPassword, username: string) => void;
  onCancel: () => void;
}

const LoginRow = memo(function LoginRow({
  index,
  top,
  measure,
  row,
  site,
  last,
  position,
  setSize,
  editing,
  strings,
  onReveal,
  onCopy,
  onEdit,
  onDelete,
  onCommit,
  onCancel,
}: LoginRowProps) {
  const { t } = strings;
  // Return submits the editor's form; Escape reaches the page as the dispatcher's `reset` command
  // (main.tsx), and leaving the field cancels. The page reads no key events itself.
  const submitUsername = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const field = event.currentTarget.elements.namedItem("username") as HTMLInputElement | null;
    onCommit(row, field?.value ?? row.username);
  };
  return (
    <div
      ref={measure}
      data-index={index}
      data-size={last ? "login-end" : "login"}
      data-key={`login:${row.id}`}
      className={`pw-site${last ? " pw-site-end" : ""}`}
      data-site={site}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={position}
      aria-setsize={setSize}
      style={{ transform: `translateY(${top}px)` }}
    >
      <div className="pw-row" data-id={row.id}>
        {editing ? (
          <form className="pw-username-form" onSubmit={submitUsername}>
            <input
              ref={editOnMount}
              name="username"
              className="pw-username-input"
              aria-label={t("passwords.page.editUsername")}
              defaultValue={row.username}
              onBlur={onCancel}
            />
          </form>
        ) : (
          <span className={row.username ? "pw-username" : "pw-username none"}>
            {row.username || t("passwords.page.noUsername")}
          </span>
        )}
        <span className="pw-badges">
          {row.weak && <span className="pw-badge">{t("passwords.page.weak")}</span>}
          {row.reused && <span className="pw-badge">{t("passwords.page.reused")}</span>}
        </span>
        <span className="pw-meta">
          {row.last_used == null
            ? t("passwords.page.neverUsed")
            : strings.format("passwords.page.lastUsed", dateFormat(strings.language).format(new Date(row.last_used)))}
        </span>
        <span className="pw-actions">
          <RowButton icon="reveal" label={t("passwords.page.reveal")} onClick={() => onReveal(row)} />
          <RowButton icon="copy" label={t("passwords.page.copy")} onClick={() => onCopy(row)} />
          <RowButton icon="edit" label={t("passwords.page.editUsername")} onClick={() => onEdit(row)} />
          <RowButton icon="delete" label={t("passwords.page.delete")} onClick={() => onDelete(row)} />
        </span>
      </div>
    </div>
  );
});

interface ListRowProps<T> extends Placed {
  row: T;
  setSize: number;
  strings: Strings;
  onRemove: (row: T) => void;
}

const PasskeyRow = memo(function PasskeyRow({
  index,
  top,
  measure,
  row,
  setSize,
  strings,
  onRemove,
}: ListRowProps<SavedPasskey>) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="passkey"
      data-key={`passkey:${row.id}`}
      className="pw-row"
      data-id={row.id}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={setSize}
      style={{ transform: `translateY(${top}px)` }}
    >
      <span className="pw-site-badge" aria-hidden="true">
        {siteInitial(row.rp_id)}
      </span>
      <span className="pw-site-name">{row.rp_id}</span>
      <span className="pw-username">{row.user_display_name || row.user_name}</span>
      <span className="pw-actions">
        <RowButton icon="delete" label={strings.t("passwords.page.delete")} onClick={() => onRemove(row)} />
      </span>
    </div>
  );
});

const ExceptionRow = memo(function ExceptionRow({
  index,
  top,
  measure,
  row,
  setSize,
  strings,
  onRemove,
}: ListRowProps<PasswordException>) {
  return (
    <div
      ref={measure}
      data-index={index}
      data-size="exception"
      data-key={`exception:${row.id}`}
      className="pw-row"
      data-id={row.id}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listitem"
      aria-posinset={index + 1}
      aria-setsize={setSize}
      style={{ transform: `translateY(${top}px)` }}
    >
      <span className="pw-site-badge" aria-hidden="true">
        {siteInitial(row.site)}
      </span>
      <span className="pw-site-name">{row.site}</span>
      <span className="pw-actions">
        <RowButton icon="delete" label={strings.t("passwords.page.remove")} onClick={() => onRemove(row)} />
      </span>
    </div>
  );
});
