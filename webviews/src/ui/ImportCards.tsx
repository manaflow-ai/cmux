// Import suggestion cards (Packages/macOS/CmuxNext CmuxNextImportCards): what this Mac has that cmux
// can bring over. The host builds every card with its text already localized (ImportCardDeck) and
// sends the list; this draws it in Settings › Import (every card, dismissed ones dimmed). Home and
// New Tab show no import suggestion. A button press goes back as the card id and its action.
import "./importCards.css";

export type ImportCardButton = { action: string; title: string };

export type ImportCardData = {
  id: string;
  kind: string;
  /// The source app's icon as a `data:image/png` URL; absent when the app is not installed.
  icon?: string;
  title: string;
  /// What was found: "3 profiles · history, bookmarks and cookies".
  facts: string;
  /// What the import gives.
  benefit: string;
  /// The agent's words, for a card the Chief raised.
  reason?: string;
  state: "ready" | "running" | "paused" | "done" | "failed" | "info";
  /// 0 to 1 while an import runs or is paused.
  progress?: number;
  status?: string;
  primary?: ImportCardButton;
  secondary: ImportCardButton[];
  dismissed: boolean;
};

export type ImportCardList = {
  title: string;
  cards: ImportCardData[];
  /// Settings › Import's text when nothing was found.
  empty?: string;
  scanning?: boolean;
};

const STATES = new Set(["ready", "running", "paused", "done", "failed", "info"]);

function text(value: unknown): string {
  return typeof value === "string" ? value.slice(0, 600) : "";
}

function button(value: unknown): ImportCardButton | null {
  const raw = value as Partial<ImportCardButton> | null;
  if (!raw || typeof raw !== "object" || typeof raw.action !== "string" || !/^[a-z]{1,16}$/.test(raw.action))
    return null;
  const title = text(raw.title);
  return title ? { action: raw.action, title } : null;
}

function card(value: unknown): ImportCardData | null {
  const raw = value as Record<string, unknown> | null;
  if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || !raw.id || !text(raw.title)) return null;
  const state =
    typeof raw.state === "string" && STATES.has(raw.state) ? (raw.state as ImportCardData["state"]) : "ready";
  const primary = button(raw.primary);
  const progress =
    typeof raw.progress === "number" && Number.isFinite(raw.progress)
      ? Math.min(1, Math.max(0, raw.progress))
      : undefined;
  return {
    id: raw.id,
    kind: text(raw.kind),
    title: text(raw.title),
    facts: text(raw.facts),
    benefit: text(raw.benefit),
    state,
    secondary: Array.isArray(raw.secondary) ? raw.secondary.map(button).filter((b) => b !== null) : [],
    dismissed: raw.dismissed === true,
    ...(typeof raw.icon === "string" && raw.icon.startsWith("data:image/png;base64,") ? { icon: raw.icon } : {}),
    ...(text(raw.reason) ? { reason: text(raw.reason) } : {}),
    ...(text(raw.status) ? { status: text(raw.status) } : {}),
    ...(primary ? { primary } : {}),
    ...(progress !== undefined ? { progress } : {}),
  };
}

/// The host's list, checked field by field; null for anything that is not one (or has no cards
/// and no empty text, which draws nothing).
export function parseImportCards(value: unknown): ImportCardList | null {
  const raw = value as Record<string, unknown> | null;
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.cards)) return null;
  const cards = raw.cards.map(card).filter((c) => c !== null);
  const empty = text(raw.empty);
  if (cards.length === 0 && !empty) return null;
  return {
    title: text(raw.title),
    cards,
    ...(empty ? { empty } : {}),
    ...(raw.scanning === true ? { scanning: true } : {}),
  };
}

function Card({ card, onAction }: { card: ImportCardData; onAction: (id: string, action: string) => void }) {
  const busy = card.state === "running";
  return (
    <article
      className="import-card"
      data-import-card={card.id}
      data-state={card.state}
      data-dismissed={card.dismissed ? "true" : undefined}
      aria-busy={busy || undefined}
    >
      <div className="import-card-head">
        {card.icon ? (
          <img className="import-card-icon" src={card.icon} alt="" width={28} height={28} />
        ) : (
          <span className="import-card-icon import-card-icon-blank" aria-hidden="true" />
        )}
        <div className="import-card-names">
          <h3 className="import-card-title">{card.title}</h3>
          {card.facts && <p className="import-card-facts">{card.facts}</p>}
        </div>
      </div>
      {card.reason && <p className="import-card-reason">“{card.reason}”</p>}
      {card.benefit && <p className="import-card-benefit">{card.benefit}</p>}
      {card.progress !== undefined && (card.state === "running" || card.state === "paused") && (
        <progress
          className="import-card-progress"
          max={100}
          value={Math.round(card.progress * 100)}
          aria-label={card.status ?? card.title}
        />
      )}
      {card.status && (
        <p className="import-card-status" role={card.state === "failed" ? "alert" : "status"}>
          {card.status}
        </p>
      )}
      {(card.primary || card.secondary.length > 0) && (
        <div className="import-card-buttons">
          {card.primary && (
            <button
              type="button"
              className="import-card-button import-card-primary"
              data-action={card.primary.action}
              onClick={() => onAction(card.id, card.primary!.action)}
            >
              {card.primary.title}
            </button>
          )}
          {card.secondary.map((secondary) => (
            <button
              key={secondary.action}
              type="button"
              className="import-card-button import-card-secondary"
              data-action={secondary.action}
              onClick={() => onAction(card.id, secondary.action)}
            >
              {secondary.title}
            </button>
          ))}
        </div>
      )}
    </article>
  );
}

/// The cards, stacked (Settings › Import).
export function ImportCards({
  list,
  onAction,
  showTitle = true,
}: {
  list: ImportCardList;
  onAction: (id: string, action: string) => void;
  showTitle?: boolean;
}) {
  return (
    <section className="import-cards" aria-label={list.title || undefined}>
      {showTitle && list.title && <h2 className="import-cards-title">{list.title}</h2>}
      {list.cards.length === 0 && list.empty ? (
        <p className="import-cards-empty">{list.empty}</p>
      ) : (
        <div className="import-cards-grid">
          {list.cards.map((c) => (
            <Card key={c.id} card={c} onAction={onAction} />
          ))}
        </div>
      )}
    </section>
  );
}
