// The pinned Needs you section under a Chief chat's header (Swift FeedNeedsYouView over the Feed's
// model, FeedNeedsYouPin): the Feed's open requests, each with what it is and who asked; a click on a
// request opens its source (its link, the tab that asked, else the Feed); the one-click answers the
// Feed row offers answer in place; past the limit the rest are counted and the count opens the Feed.
// Opt-in (Settings > Notifications > Feed > Pin Needs You in Chief), off by default: the host sends
// nothing while it is off. Every word comes from the host (the Feed's own strings).
//
// Looks (FeedNeedsYouStyle): `rows` (picked, the Feed's default), `bar` (one line: the first request
// and the count), `cards` (each request in its own card).

/** One answer a request offers in place. */
export interface NeedsYouAnswer {
  id: string;
  title: string;
  role: "plain" | "primary" | "destructive";
  /** False while the Feed sends an earlier answer or is offline. */
  enabled: boolean;
}

export interface NeedsYouRow {
  id: string;
  headline: string;
  /** Who asked and where (the Feed row's meta line). */
  who: string;
  urgent: boolean;
  answers: readonly NeedsYouAnswer[];
}

export interface NeedsYouState {
  title: string;
  rows: readonly NeedsYouRow[];
  /** "2 more", when some are not listed. */
  more?: string;
  look: NeedsYouLook;
}

export type NeedsYouLook = "rows" | "bar" | "cards";

export interface NeedsYouSectionProps {
  state: NeedsYouState;
  onOpen(id: string): void;
  onAnswer(id: string, answer: string): void;
  onShowAll(): void;
}

export function NeedsYouSection({ state, onOpen, onAnswer, onShowAll }: NeedsYouSectionProps) {
  const first = state.rows[0];
  if (!first) return null;
  if (state.look === "bar") {
    const count = state.rows.length;
    return (
      <section className="ny-section ny-bar" aria-label={state.title}>
        <button
          type="button"
          className="ny-open"
          onClick={() => (count === 1 && !state.more ? onOpen(first.id) : onShowAll())}
        >
          <span className={`ny-dot${first.urgent ? " urgent" : ""}`} aria-hidden="true" />
          <span className="ny-title">{state.title}</span>
          <span className="ny-headline">{first.headline}</span>
        </button>
      </section>
    );
  }
  return (
    <section className={`ny-section ny-${state.look}`} aria-label={state.title}>
      <header className="ny-head">
        <span className="ny-title">{state.title}</span>
        <span className="ny-count">{state.rows.length}</span>
        {state.more && (
          <button type="button" className="ny-more" onClick={onShowAll}>
            {state.more}
          </button>
        )}
      </header>
      {state.rows.map((row) => (
        <div key={row.id} className="ny-row">
          <button type="button" className="ny-open" onClick={() => onOpen(row.id)} title={row.headline}>
            <span className={`ny-dot${row.urgent ? " urgent" : ""}`} aria-hidden="true" />
            <span className="ny-text">
              <span className="ny-headline">{row.headline}</span>
              {row.who && <span className="ny-who">{row.who}</span>}
            </span>
          </button>
          {row.answers.length > 0 && (
            <span className="ny-answers">
              {row.answers.map((answer) => (
                <button
                  key={answer.id}
                  type="button"
                  className={`ny-answer ${answer.role}`}
                  disabled={!answer.enabled}
                  onClick={() => onAnswer(row.id, answer.id)}
                >
                  {answer.title}
                </button>
              ))}
            </span>
          )}
        </div>
      ))}
    </section>
  );
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const ROLES = new Set(["plain", "primary", "destructive"]);
const LOOKS = new Set(["rows", "bar", "cards"]);

/** The host's `needsYou` event, or undefined (nothing waits, the section is off, not a Chief chat). */
export function parseNeedsYou(event: unknown): NeedsYouState | undefined {
  const raw = record(event);
  const title = text(raw?.title);
  if (!raw || !title || !Array.isArray(raw.rows)) return undefined;
  const rows: NeedsYouRow[] = [];
  for (const entry of raw.rows) {
    const row = record(entry);
    const id = text(row?.id);
    const headline = text(row?.headline);
    if (!row || !id || !headline) continue;
    const answers: NeedsYouAnswer[] = [];
    for (const value of Array.isArray(row.answers) ? row.answers : []) {
      const answer = record(value);
      const answerID = text(answer?.id);
      const answerTitle = text(answer?.title);
      if (!answer || !answerID || !answerTitle) continue;
      const role = typeof answer.role === "string" && ROLES.has(answer.role) ? answer.role : "plain";
      answers.push({
        id: answerID,
        title: answerTitle,
        role: role as NeedsYouAnswer["role"],
        enabled: answer.enabled !== false,
      });
    }
    rows.push({ id, headline, who: text(row.who) ?? "", urgent: row.urgent === true, answers });
  }
  if (rows.length === 0) return undefined;
  const look = typeof raw.look === "string" && LOOKS.has(raw.look) ? (raw.look as NeedsYouLook) : "rows";
  return { title, rows, ...(text(raw.more) ? { more: text(raw.more)! } : {}), look };
}
