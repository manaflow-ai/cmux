import { useEffect, useId, useMemo, useRef, useState } from "react";
import { focusRoute } from "../../ui/focusRoute";
import { useT } from "./i18n";
import { ChevronDown, Envelope, Magnifier } from "./conversation/icons";
import { ExpandRow } from "./conversation/ExpandRow";
import { InboxNoticeCard, type ReadInboxThread } from "./conversation/InboxNoticeCard";
import { PromptMarksSession } from "./threadMinimap/promptMarks";
import {
  HELD_PAGE,
  heldThreads,
  listFailure,
  retriesItself,
  retryDelay,
  searchThreads,
  surgeShows,
  type HeldThread,
  type ListFailure,
  type SurgeHold,
} from "./conversation/surgeHold";
import { errorMessage } from "./transportErrors";
import "./SurgeHoldRow.css";

/// How the line reads (the gallery's variants; the shipped look is `counts`).
export type SurgeRowLook = "counts" | "sentence" | "needFirst";

type Listing =
  | { state: "loading" }
  | { state: "failed"; failure: ListFailure; reason: string }
  | { state: "ready"; threads: HeldThread[] };

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
  look = "counts",
  connected = true,
  initiallyOpen = false,
}: {
  surge: SurgeHold | undefined;
  sessionId: string;
  /// `_acpmux/inbox_threads` for the chat (its reply as acpmux sent it).
  listThreads(): Promise<unknown>;
  readThread: ReadInboxThread;
  onOpenSender(sessionId: string): void;
  look?: SurgeRowLook;
  /// Whether the pane is connected to acpmux now: while it is not, the open panel says so and reads
  /// nothing; it reads by itself once the connection is back.
  connected?: boolean;
  initiallyOpen?: boolean;
}) {
  const t = useT();
  const [open, setOpen] = useState(initiallyOpen);
  const [onlyNeed, setOnlyNeed] = useState(false);
  const [query, setQuery] = useState("");
  const [shown, setShown] = useState(HELD_PAGE);
  const [listing, setListing] = useState<Listing>({ state: "loading" });
  const [attempt, setAttempt] = useState(0);
  const tries = useRef(0);
  const panelId = useId();
  const field = useRef<HTMLInputElement>(null);
  // The listing is read when the panel opens and again when a new snapshot moves the counts while it
  // is open: one read per change the person can see, never a poll.
  const held = surge?.held ?? 0;
  const needYou = surge?.needYou ?? 0;
  // A new snapshot or a reopened panel starts the retries over (declared first, so it runs before the
  // read below).
  useEffect(() => {
    tries.current = 0;
  }, [open, held, needYou]);
  useEffect(() => {
    if (!open) return;
    if (!connected) {
      setListing({ state: "failed", failure: { kind: "offline" }, reason: "" });
      return;
    }
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    listThreads().then(
      (reply) => {
        if (!live) return;
        tries.current = 0;
        setListing({ state: "ready", threads: heldThreads(reply) });
      },
      (error: unknown) => {
        if (!live) return;
        const failure = listFailure(error);
        // A transient failure reads again by itself, on a jittered backoff, while the panel is open;
        // past the last try it says so quietly and reads again on the next snapshot. A failure no
        // retry can help (the host's refusal, acpmux's own error) says what failed, with no button.
        const wait = retriesItself(failure) ? retryDelay(tries.current) : undefined;
        if (wait === undefined) {
          // The failure keeps its own words too: a bare "Try again" told Leo nothing (2026-11-22).
          setListing({ state: "failed", failure, reason: failure.kind === "other" ? errorMessage(error) : "" });
          return;
        }
        tries.current += 1;
        timer = setTimeout(() => setAttempt((n) => n + 1), wait);
      },
    );
    return () => {
      live = false;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [open, held, needYou, attempt, listThreads, connected]);
  const threads = listing.state === "ready" ? listing.threads : undefined;
  // The search field shows once there are threads to search; it takes the focus then.
  const searchable = open && threads !== undefined && threads.length > 0;
  useEffect(() => {
    if (searchable)
      focusRoute(field.current, "person", "the held messages panel opened: its search field", { preventScroll: true });
  }, [searchable]);
  const found = useMemo(() => {
    const all = threads ?? [];
    return searchThreads(onlyNeed ? all.filter((thread) => thread.blocker) : all, query);
  }, [threads, onlyNeed, query]);
  if (!surgeShows(surge)) return null;
  const toggle = (next: boolean, needOnly = false) => {
    setOpen(next);
    setOnlyNeed(next && needOnly);
    if (next) setShown(HELD_PAGE);
  };
  const heldText = t("surge.held", { n: held });
  const needText = t("surge.needYou", { n: needYou });
  const lineText =
    look === "sentence"
      ? needYou > 0
        ? t("surge.sentenceNeed", { held, need: needYou })
        : t("surge.sentence", { held })
      : [look === "needFirst" && needYou > 0 ? needText : "", t("surge.title"), heldText].filter(Boolean).join(", ");
  return (
    // The stack's own material and edge, as the goal row, the questions band and the tray take them.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape from any control inside (search, filters, threads) closes the open panel; the controls themselves take the keyboard.
    <section
      className="ui-glass ui-glass-floats acpmux-stack-material acpmux-surge"
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
          {/* Search only what is there to search: no field over a failure or an empty listing. */}
          {searchable && (
            <label className="acpmux-surge-search">
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
            </label>
          )}
          {needYou > 0 && searchable && (
            <fieldset className="acpmux-surge-filters">
              <button type="button" aria-pressed={!onlyNeed} onClick={() => setOnlyNeed(false)}>
                {heldText}
              </button>
              <button type="button" aria-pressed={onlyNeed} onClick={() => setOnlyNeed(true)}>
                {needText}
              </button>
            </fieldset>
          )}
          <div className="acpmux-surge-threads">
            {listing.state === "loading" ? (
              <p className="acpmux-surge-note">{t("surge.loading")}</p>
            ) : listing.state === "failed" ? (
              <div className="acpmux-surge-failed" role="alert" data-failure={listing.failure.kind}>
                <p className="acpmux-surge-failed-copy">
                  <span className="acpmux-surge-failed-title">{failureText(t, listing.failure)}</span>
                  {listing.reason && <span className="acpmux-surge-failed-reason">{listing.reason}</span>}
                </p>
              </div>
            ) : found.length === 0 ? (
              <p className="acpmux-surge-note" data-empty={threads?.length === 0 ? "unmarked" : "search"}>
                {threads?.length === 0 ? t("surge.noneMarked") : t("surge.noMatch")}
              </p>
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
          </div>
        </section>
      )}
      {/* The line is one button under its words (the goal row's pattern, TaskGoalStrip.css), so the
          need-you button can stand in the column before the chevron, which ends the line. */}
      <div className="acpmux-surge-line">
        <button
          type="button"
          className="acpmux-surge-toggle"
          aria-label={lineText}
          aria-expanded={open}
          aria-controls={open ? panelId : undefined}
          onClick={() => toggle(!open)}
        />
        <span className="acpmux-surge-mark" aria-hidden="true">
          <Envelope size={14} />
        </span>
        {look === "sentence" ? (
          <span className="acpmux-surge-copy" aria-hidden="true">
            {lineText}
          </span>
        ) : (
          <span className="acpmux-surge-copy" aria-hidden="true">
            {look === "needFirst" && needYou > 0 && <span className="acpmux-surge-need">{needText}</span>}
            <span className="acpmux-surge-title">{t("surge.title")}</span>
            <span className="acpmux-surge-count">{heldText}</span>
          </span>
        )}
        {look === "counts" && needYou > 0 && (
          // The ones that need the person open the panel on them alone.
          <button type="button" className="acpmux-surge-need" onClick={() => toggle(true, true)}>
            {needText}
          </button>
        )}
        <ChevronDown size={12} className="acpmux-surge-chevron" aria-hidden="true" />
      </div>
    </section>
  );
}

/// What the open panel says when the held threads could not be listed (conversation/surgeHold.ts
/// `listFailure`): what failed, and the step that helps.
function failureText(t: ReturnType<typeof useT>, failure: ListFailure): string {
  switch (failure.kind) {
    case "host":
      return t("surge.failedHost");
    case "daemonOld":
      return t("surge.failedOld");
    case "offline":
      return t("surge.failedOffline");
    case "daemon":
      return t("surge.failedDaemon", { why: failure.why });
    case "other":
      return t("surge.loadFailed");
  }
}
