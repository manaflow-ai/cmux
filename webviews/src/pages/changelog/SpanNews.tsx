// "What's new since your last update" as happy news (Leo 2026-10-21: "make it read like happy
// news"): the top two or three changes lead, each with its picture or clip playing in place; the
// rest of New and Improved follow as cards in a grid; Fixed folds into one line. Security keeps
// its list, open: it is the one group a person must not miss.
import type { ReleaseItem, ReleaseView } from "./model";
import { categoryLabel, Groups, ItemActions, Media, RowActions, type PartsContext } from "./ReleaseParts";

/** At most this many changes lead the section. */
const LEAD_MAX = 3;
/** A lead without a picture only fills the row up to this many. */
const LEAD_MIN = 2;

/** The changes that lead: the view's hero, the other New and Improved changes with a picture,
    then New ones while fewer than LEAD_MIN lead. */
export function leadItems(view: ReleaseView): ReleaseItem[] {
  const lead = view.hero ? [view.hero] : [];
  const news = newsItems(view);
  for (const item of news) if (lead.length < LEAD_MAX && item.media && !lead.includes(item)) lead.push(item);
  for (const item of news)
    if (lead.length < LEAD_MIN && item.category === "new" && !lead.includes(item)) lead.push(item);
  return lead;
}

function newsItems(view: ReleaseView): ReleaseItem[] {
  return view.groups.filter((g) => g.category === "new" || g.category === "improved").flatMap((g) => g.items);
}

function firstParagraph(text: string): string {
  return text.split(/\n{2,}/)[0] ?? "";
}

export function SpanNews({ view, ctx }: { view: ReleaseView; ctx: PartsContext }) {
  const lead = leadItems(view);
  const cards = newsItems(view).filter((item) => !lead.includes(item));
  const security = view.groups.filter((g) => g.category === "security");
  const fixed = view.groups.find((g) => g.category === "fixed")?.items ?? [];
  // When fixes are all the update's news, their list is open: one closed line would hide all of it.
  const onlyFixes = lead.length === 0 && cards.length === 0 && security.length === 0;
  return (
    <>
      {lead.length > 0 && (
        <div className="cln-lead-row" data-count={lead.length}>
          {lead.map((item, index) => (
            <article key={`${item.id}-${index}`} className="cln-lead">
              {item.media && <Media media={item.media} className="cln-lead-media" />}
              <h2 className="cln-lead-title">{item.title}</h2>
              {item.summary && <p className="cln-lead-summary">{firstParagraph(item.summary)}</p>}
              <ItemActions item={item} ctx={ctx} />
            </article>
          ))}
        </div>
      )}
      {cards.length > 0 && (
        <ul className="cln-cards">
          {cards.map((item, index) => (
            <li key={`${item.id}-${index}`} className="cln-card">
              <span className="cln-card-kind">{categoryLabel(ctx.strings, item.category)}</span>
              <h3 className="cln-card-title">{item.title}</h3>
              {item.summary && <p className="cln-card-summary">{firstParagraph(item.summary)}</p>}
              {item.media && <Media media={item.media} className="cln-card-media" />}
              <RowActions item={item} ctx={ctx} />
            </li>
          ))}
        </ul>
      )}
      {security.length > 0 && <Groups view={{ ...view, groups: security }} ctx={ctx} />}
      {fixed.length > 0 && (
        <details className="cln-fixed" open={onlyFixes}>
          <summary>
            {categoryLabel(ctx.strings, "fixed")}
            <span className="cl-count">{fixed.length}</span>
          </summary>
          <ul>
            {fixed.map((item, index) => (
              <li key={`${item.id}-${index}`}>
                <span className="cl-row-text">
                  <span className="cl-row-title">{item.title}</span>
                  {item.summary && <span className="cl-row-summary"> {firstParagraph(item.summary)}</span>}
                </span>
                <RowActions item={item} ctx={ctx} />
              </li>
            ))}
          </ul>
        </details>
      )}
    </>
  );
}
