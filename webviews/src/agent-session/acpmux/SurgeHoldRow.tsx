import { useEffect, useId, useMemo, useRef, useState } from "react";
import { focusRoute } from "../../ui/focusRoute";
import { useT } from "./i18n";
import { ChevronDown, Envelope, Magnifier } from "./conversation/icons";
import { ExpandRow } from "./conversation/ExpandRow";
import { InboxNoticeCard, type ReadInboxThread } from "./conversation/InboxNoticeCard";
import { PromptMarksSession } from "./threadMinimap/promptMarks";
import {
  ARCHIVE_DEBOUNCE_MS,
  ARCHIVE_MIN_CHARS,
  HELD_PAGE,
  heldThreads,
  searchThreads,
  surgeCounts,
  surgeShows,
  type HeldThread,
  type SurgeHold,
} from "./conversation/surgeHold";
import { SurgeArchiveResults, type SearchArchive } from "./SurgeArchiveResults";
import "./SurgeHoldRow.css";

/// How the line reads (the gallery's variants; the shipped look is `counts`).
export type SurgeRowLook = "counts" | "sentence" | "needFirst";

/// A ready listing keeps the counts it answered for (`at`): the snapshot it saw.
type Listing = { state: "loading" } | { state: "failed" } | { state: "ready"; threads: HeldThread[]; at: string };

/// The chat's held surge as one row of the composer hat (conversation/surgeHold.ts): how many
/// messages its inbox holds without a turn and how many of them need the person, updated in place as
/// acpmux's snapshots come, never a row per held message. A click opens the held threads over the
/// row: a search field, then each thread as another agent's received line (InboxNoticeCard.tsx, the
/// transcript's received-messages look), the ones that need the person first, `HELD_PAGE` at a time.
/// Opening a line reads its posts from acpmux without marking them read (the person reading is not
/// the agent).
export function SurgeHoldRow({
  surge,
  sessionId,
  listThreads,
  readThread,
  onOpenSender,
  searchArchive,
  look = "counts",
  initiallyOpen = false,
}: {
  surge: SurgeHold | undefined;
  sessionId: string;
  /// `_acpmux/inbox_threads` for the chat (its reply as acpmux sent it).
  listThreads(): Promise<unknown>;
  readThread: ReadInboxThread;
  onOpenSender(sessionId: string): void;
  /// The inbox's archive (`_acpmux/inbox_threads` with `search`): posts evicted from the live inbox
  /// and older text in live threads. Without it the search filters the listed threads alone.
  searchArchive?: SearchArchive;
  look?: SurgeRowLook;
  initiallyOpen?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(initiallyOpen);
  const [onlyNeed, setOnlyNeed] = useState(false);
  const [query, setQuery] = useState("");
  // The search the archive is asked for: the field's text once it rests `ARCHIVE_DEBOUNCE_MS`, or at
  // once on Enter; shorter than `ARCHIVE_MIN_CHARS`, none.
  const [submitted, setSubmitted] = useState("");
  const asked = query.trim().length >= ARCHIVE_MIN_CHARS ? query.trim() : "";
  useEffect(() => {
    if (!asked) {
      setSubmitted("");
      return;
    }
    const timer = setTimeout(() => setSubmitted(asked), ARCHIVE_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [asked]);
  const [shown, setShown] = useState(HELD_PAGE);
  const [listing, setListing] = useState<Listing>({ state: "loading" });
  // Each read asked for (a new number reads once): the panel's first opening, an opening on counts
  // the last read did not see, Refresh, Try again. None while shut (the chat's attach brings its
  // counts, direct.ts), and never a snapshot arriving while the panel is open.
  const [wanted, setWanted] = useState(initiallyOpen ? 1 : 0);
  const panelId = useId();
  const field = useRef<HTMLInputElement>(null);
  const held = surge?.held ?? 0;
  const needYou = surge?.needYou ?? 0;
  const counts = `${held}\u0000${needYou}`;
  const latest = useRef(counts);
  // The listing reader by reference, for the same reason as the counts: a new function on a redraw
  // reads nothing.
  const listRef = useRef(listThreads);
  useEffect(() => {
    listRef.current = listThreads;
  }, [listThreads]);
  useEffect(() => {
    latest.current = counts;
  }, [counts]);
  // A read only when one is asked for (`wanted`): the row's counts come with the chat's attach, so a
  // chat that never opens the panel reads no listing, and a surge of posts while it is open costs no
  // read per post.
  useEffect(() => {
    if (wanted === 0) return;
    let live = true;
    const at = latest.current;
    listRef.current().then(
      (reply) => {
        if (!live) return;
        // The reply's own snapshot when it carries one (the row moves to it too), else the counts
        // the read was asked at.
        const own = surgeCounts((reply as { surge?: unknown } | null)?.surge);
        const listedAt = own ? `${own.held}\u0000${own.needYou}` : at;
        setListing({ state: "ready", threads: heldThreads(reply), at: listedAt });
      },
      () => live && setListing({ state: "failed" }),
    );
    return () => {
      live = false;
    };
  }, [wanted]);
  // New messages came since the listing: the open panel offers Refresh rather than reading again.
  const stale = listing.state === "ready" && listing.at !== counts;
  useEffect(() => {
    if (open)
      focusRoute(field.current, "person", "the held messages panel opened: its search field", { preventScroll: true });
  }, [open]);
  const threads = listing.state === "ready" ? listing.threads : undefined;
  const found = useMemo(() => {
    const all = threads ?? [];
    return searchThreads(onlyNeed ? all.filter((thread) => thread.needYou) : all, query);
  }, [threads, onlyNeed, query]);
  if (!surgeShows(surge)) return null;
  const toggle = (next: boolean, needOnly = false) => {
    setOpen(next);
    setOnlyNeed(next && needOnly);
    if (next) setShown(HELD_PAGE);
    // The first opening reads the listing; one on counts the last listing did not see (or after a
    // failed one) reads once more.
    if (next && (wanted === 0 || stale || listing.state === "failed")) setWanted(wanted + 1);
  };
  const heldText = t("surge.held", { n: held });
  const needText = t("surge.needYou", { n: needYou });
  return (
    <section
      className="acpmux-surge"
      data-open={open || undefined}
      data-need={needYou > 0 || undefined}
      data-look={look}
      aria-label={t("surge.title")}
      onKeyDown={(event) => {
        if (event.key === "Escape" && open) {
          event.stopPropagation();
          toggle(false);
        }
      }}
    >
      {open && (
        <section id={panelId} className="acpmux-surge-panel" aria-label={t("surge.title")}>
          <form
            className="acpmux-surge-search"
            onSubmit={(event) => {
              // Enter asks the archive at once, without waiting for the field to rest.
              event.preventDefault();
              setSubmitted(asked);
            }}
          >
            <Magnifier size={14} />
            <input
              ref={field}
              type="search"
              value={query}
              placeholder={t("surge.search")}
              aria-label={t("surge.search")}
              onChange={(event) => {
                setQuery(event.target.value);
                setShown(HELD_PAGE);
              }}
            />
          </form>
          {needYou > 0 && (
            <div className="acpmux-surge-filters">
              <button type="button" aria-pressed={!onlyNeed} onClick={() => setOnlyNeed(false)}>
                {heldText}
              </button>
              <button type="button" aria-pressed={onlyNeed} onClick={() => setOnlyNeed(true)}>
                {needText}
              </button>
            </div>
          )}
          {stale && (
            <button type="button" className="acpmux-surge-refresh" onClick={() => setWanted(wanted + 1)}>
              {t("surge.refresh")}
            </button>
          )}
          <div className="acpmux-surge-threads">
            {listing.state === "loading" ? (
              <p className="acpmux-surge-note">{t("surge.loading")}</p>
            ) : listing.state === "failed" ? (
              <p className="acpmux-surge-note" role="alert">
                {t("surge.loadFailed")}{" "}
                <button type="button" className="acpmux-surge-retry" onClick={() => setWanted(wanted + 1)}>
                  {t("surge.retry")}
                </button>
              </p>
            ) : found.length === 0 ? (
              <p className="acpmux-surge-note">{t("surge.noMatch")}</p>
            ) : (
              <PromptMarksSession.Provider value={`surge:${sessionId}`}>
                <div className="cv-incoming">
                  {found.slice(0, shown).map((thread) => (
                    <InboxNoticeCard
                      key={thread.threadId}
                      rowId={`surge-${sessionId}`}
                      notice={{ threads: [thread] }}
                      onOpen={onOpenSender}
                      readThread={readThread}
                    />
                  ))}
                </div>
                {found.length > shown && (
                  <ExpandRow
                    className="acpmux-surge-more"
                    open={false}
                    label={t("surge.more", { n: found.length - shown })}
                    onToggle={() => setShown(shown + HELD_PAGE)}
                  />
                )}
              </PromptMarksSession.Provider>
            )}
            {searchArchive && submitted && (
              <SurgeArchiveResults key={submitted} query={submitted} search={searchArchive} />
            )}
          </div>
        </section>
      )}
      <div className="acpmux-surge-line">
        <button
          type="button"
          className="acpmux-surge-toggle"
          aria-expanded={open}
          aria-controls={open ? panelId : undefined}
          onClick={() => toggle(!open)}
        >
          <span className="acpmux-surge-mark" aria-hidden="true">
            <Envelope size={14} />
          </span>
          {look === "sentence" ? (
            <span className="acpmux-surge-copy">
              {needYou > 0 ? t("surge.sentenceNeed", { held, need: needYou }) : t("surge.sentence", { held })}
            </span>
          ) : (
            <span className="acpmux-surge-copy">
              {look === "needFirst" && needYou > 0 && <span className="acpmux-surge-need">{needText}</span>}
              <span className="acpmux-surge-title">{t("surge.title")}</span>
              <span className="acpmux-surge-count">{heldText}</span>
            </span>
          )}
          <ChevronDown size={12} className="acpmux-surge-chevron" />
        </button>
        {look === "counts" && needYou > 0 && (
          // The ones that need the person open the panel on them alone.
          <button type="button" className="acpmux-surge-need" onClick={() => toggle(true, true)}>
            {needText}
          </button>
        )}
      </div>
    </section>
  );
}
