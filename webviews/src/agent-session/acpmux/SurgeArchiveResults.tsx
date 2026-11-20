import { useEffect, useRef, useState } from "react";
import { useT } from "./i18n";
import { useMinuteClock } from "./clock";
import { shortAge } from "./sessionList";
import { ChevronDown } from "./conversation/icons";
import { ExpandRow } from "./conversation/ExpandRow";
import { Markdown } from "./conversation/Markdown";
import { messagePreview } from "./conversation/agentMessageRowModel";
import { bareSender } from "./conversation/senderIdentity";
import { withoutRelayEnvelope } from "./conversation/relayEnvelope";
import { appendArchive, archivePage, type ArchiveHit } from "./conversation/surgeHold";

/// Asks the inbox's archive for a page of posts matching `search` (`_acpmux/inbox_threads` with
/// `{search, before?}`): its reply as acpmux sent it.
export type SearchArchive = (search: string, before?: string | number) => Promise<unknown>;

type Results =
  | { state: "searching"; hits: ArchiveHit[] }
  | { state: "failed"; hits: ArchiveHit[] }
  | { state: "ready"; hits: ArchiveHit[]; next?: string | number };

/// The held messages panel's archive results (SurgeHoldRow.tsx): every post the chat's inbox ever
/// held that matches the submitted search, including those evicted from the live inbox and older
/// text in a live thread, newest first as acpmux pages them. One read per submitted search and one
/// per "More results", never one per arriving post. A hit opens to its whole original text.
export function SurgeArchiveResults({ query, search }: { query: string; search: SearchArchive }) {
  const t = useT();
  const now = useMinuteClock();
  const [results, setResults] = useState<Results>({ state: "searching", hits: [] });
  // The page asked for: `undefined` is the first; a cursor reads the one after it.
  // A new search mounts anew (its parent keys it by the search), so it starts at its first page.
  const [before, setBefore] = useState<{ at?: string | number }>({});
  const [opened, setOpened] = useState<ReadonlySet<number>>(() => new Set());
  // The reader by reference: a parent that hands a new function on each draw (each arriving post)
  // never asks the archive again.
  const searchRef = useRef(search);
  useEffect(() => {
    searchRef.current = search;
  }, [search]);
  useEffect(() => {
    let live = true;
    const first = before.at === undefined;
    if (!first) setResults((current) => ({ state: "searching", hits: current.hits }));
    searchRef.current(query, before.at).then(
      (reply) => {
        if (!live) return;
        const page = archivePage(reply);
        setResults((current) => ({
          state: "ready",
          hits: first ? page.hits : appendArchive(current.hits, page),
          ...(page.next !== undefined && { next: page.next }),
        }));
      },
      () => live && setResults((current) => ({ state: "failed", hits: first ? [] : current.hits })),
    );
    return () => {
      live = false;
    };
  }, [query, before]);
  const toggle = (seq: number) => {
    const next = new Set(opened);
    if (!next.delete(seq)) next.add(seq);
    setOpened(next);
  };
  return (
    <section
      className="acpmux-surge-archive"
      aria-label={t("surge.archiveTitle")}
      aria-busy={results.state === "searching"}
    >
      <h3 className="acpmux-surge-archive-title">{t("surge.archiveTitle")}</h3>
      {results.hits.length > 0 && (
        <ul className="acpmux-surge-hits">
          {results.hits.map((hit) => {
            const open = opened.has(hit.seq);
            const from = bareSender(hit.from).name;
            const body = withoutRelayEnvelope(hit.text);
            return (
              <li key={hit.seq} className="acpmux-surge-hit" data-open={open || undefined}>
                <button
                  type="button"
                  className="acpmux-surge-hit-line"
                  aria-expanded={open}
                  onClick={() => toggle(hit.seq)}
                >
                  <span className="acpmux-surge-hit-from">{from}</span>
                  {hit.at !== undefined && <span className="acpmux-surge-hit-age">{shortAge(hit.at, now, t)}</span>}
                  {!open && <span className="acpmux-surge-hit-preview">{messagePreview(body)}</span>}
                  <ChevronDown size={12} className="acpmux-surge-chevron" />
                </button>
                {open && (
                  // The whole original post, as the agent would have read it.
                  <div className="acpmux-surge-hit-body cv-received__text selectable">
                    <Markdown commits="quiet" messageAt={hit.at}>
                      {body}
                    </Markdown>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {results.state === "searching" ? (
        <p className="acpmux-surge-note">{t("surge.archiveSearching")}</p>
      ) : results.state === "failed" ? (
        <p className="acpmux-surge-note" role="alert">
          {t("surge.archiveFailed")}{" "}
          <button type="button" className="acpmux-surge-retry" onClick={() => setBefore({ ...before })}>
            {t("surge.retry")}
          </button>
        </p>
      ) : results.hits.length === 0 ? (
        <p className="acpmux-surge-note">{t("surge.archiveNone")}</p>
      ) : results.next !== undefined ? (
        <ExpandRow
          className="acpmux-surge-more"
          open={false}
          label={t("surge.archiveMore")}
          onToggle={() => setBefore({ at: results.next })}
        />
      ) : null}
    </section>
  );
}
