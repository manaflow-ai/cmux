// "What's new since your last update" as happy news (Leo 2026-10-21: "make it read like happy
// news"): the top two or three changes lead, each with its picture or clip playing in place; the
// rest of New and Improved follow as cards in a grid; Fixed folds into one line. Security keeps
// its list, open: it is the one group a person must not miss.
//
// Every change with a clip shows it at the clip's own shape, uncut, with its caption: what you can
// now do (Leo 2026-10-24: "it's like you're not even showing anything properly off"). A clip is the
// feature in use, cropped to where it happens (scripts/cmux-next/media/whats-new-clips.py), so it is
// never boxed and cropped again here. `ctx.news` picks how they sit (NewsLayout); "lead" is the row
// of three the clips replaced.
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

/** What the clip shows you can now do: its caption (the clip's alt, release-notes.py), else the
    change's first paragraph. */
function clipCaption(item: ReleaseItem): string {
  const alt = item.media?.alt?.trim();
  return alt && alt !== item.title ? alt : firstParagraph(item.summary);
}

function firstParagraph(text: string): string {
  return text.split(/\n{2,}/)[0] ?? "";
}

/** The changes that show a clip: the hero first, then New and Improved in order. */
export function clipItems(view: ReleaseView): ReleaseItem[] {
  const items = [...(view.hero ? [view.hero] : []), ...newsItems(view)];
  return items.filter((item, index) => item.media && items.indexOf(item) === index);
}

export function SpanNews({ view, ctx }: { view: ReleaseView; ctx: PartsContext }) {
  const layout = ctx.news ?? "alternate";
  const clips = layout === "lead" ? [] : clipItems(view);
  // Without clips (or in the old layout) the lead row stays as it was; beside clips, only a hero
  // with none leads, in words.
  const lead = clips.length === 0 ? leadItems(view) : view.hero && !view.hero.media ? [view.hero] : [];
  const cards = newsItems(view).filter((item) => !lead.includes(item) && !clips.includes(item));
  const security = view.groups.filter((g) => g.category === "security");
  const fixed = view.groups.find((g) => g.category === "fixed")?.items ?? [];
  // When fixes are all the update's news, their list is open: one closed line would hide all of it.
  const onlyFixes = clips.length === 0 && lead.length === 0 && cards.length === 0 && security.length === 0;
  return (
    <>
      {clips.length > 0 && (
        <div className={`cln-clips cln-clips-${layout}`}>
          {clips.map((item, index) => (
            <article key={`${item.id}-${index}`} className="cln-clip">
              <Media media={item.media!} className="cln-clip-media" strings={ctx.strings} />
              <div className="cln-clip-text">
                <span className="cln-card-kind">{categoryLabel(ctx.strings, item.category)}</span>
                <h2 className="cln-clip-title">{item.title}</h2>
                <p className="cln-clip-caption">{clipCaption(item)}</p>
                <ItemActions item={item} ctx={ctx} />
              </div>
            </article>
          ))}
        </div>
      )}
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
