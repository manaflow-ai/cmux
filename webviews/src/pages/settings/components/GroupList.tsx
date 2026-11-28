import { memo, startTransition, useEffect, useState, Fragment } from "react";
import type { SchemaRow } from "../schema";
import type { CategoryGroup } from "../categories";
import { text } from "../strings";
import { APP_LANGUAGE_KEY, LanguageRelaunchRow } from "./LanguageRelaunchRow";
import { SettingRow } from "./SettingRow";
import { MoreOptions } from "./MoreOptions";
import type { ArrangedGroup } from "../rowLevels";
import { GroupHeader } from "./GroupHeader";

/** Rows a category draws in its first frame: more than a tall window shows. */
const FIRST_FRAME_ROWS = 24;

/**
 * Whether this document has drawn a category yet. The first one draws whole: the host shows it only
 * once its first screen is in (paintGate.ts), and when the transition that adds the rest lost the
 * race with the user's values, the first frame shown had 24 rows and a short page that then grew
 * (test/settings-open-frames.test.ts). Opening another category later still draws 24 rows first.
 */
let drewFirstCategory = false;

/** The next category drawn draws whole, as the first does: a language change draws the shown
 * category again (SettingsPage), and a page cut to 24 rows would shorten under its scroll offset. */
export function drawNextCategoryWhole(): void {
  drewFirstCategory = false;
}

/**
 * A group's title as its page draws it (leo-workspace design/settings.md, "No title repeats its
 * page's"): none when it is the page's own title (Updates > "Updates"), and only what follows when
 * it starts with the page's title and a colon (Updates > "Updates: Advanced" reads "Advanced").
 * Search results pass no page title: there a group's whole title is the context.
 */
export function shownGroupTitle(title: string, pageTitle?: string): string {
  if (!pageTitle) return title;
  const page = pageTitle.trim().toLocaleLowerCase();
  const own = title.trim();
  if (own.toLocaleLowerCase() === page) return "";
  const head = own.slice(0, page.length).toLocaleLowerCase();
  const rest = own.slice(page.length).match(/^\s*[:：]\s*(.+)$/u);
  return head === page && rest ? rest[1] : own;
}

/**
 * Rows under their group titles, separated by spacing and hairlines; no fills. With `shown` (a
 * filter), rows and groups outside it collapse in place instead of unmounting. With `pageTitle`
 * (a category's page), a group title never repeats it (shownGroupTitle).
 */
export function GroupList({
  groups,
  query,
  focus,
  shown,
  mounted,
  pageTitle,
  groupHelp,
}: {
  groups: (CategoryGroup | ArrangedGroup)[];
  query?: string;
  focus?: string | null;
  shown?: ReadonlySet<string>;
  /** With a filter: the rows that draw their editors (the rest are empty collapsed slots). */
  mounted?: ReadonlySet<string>;
  /** The category page's own title; its groups' titles leave it out (shownGroupTitle). */
  pageTitle?: string;
  groupHelp?: Readonly<Record<string, string>>;
}) {
  // Opening a category draws the rows a window can show (and the focused one) at once and the
  // rest in a transition after that frame, so a 123-row category opens at the cost of 24 rows.
  const focusIndex = focus ? groups.flatMap((group) => group.rows).findIndex((row) => row.key === focus) : -1;
  const [all, setAll] = useState(() => !drewFirstCategory);
  useEffect(() => {
    drewFirstCategory = true;
    if (!all) startTransition(() => setAll(true));
  }, [all]);
  const limit = shown || all ? Number.POSITIVE_INFINITY : Math.max(FIRST_FRAME_ROWS, focusIndex + 1);
  let before = 0;
  return groups.map((group) => {
    const first = before;
    before += group.rows.length;
    if (first >= limit) return null;
    const rows = group.rows.slice(0, limit - first);
    const open = !shown || group.rows.some((row) => shown.has(row.key));
    const proposed = group as ArrangedGroup;
    const title = proposed.untitled ? "" : shownGroupTitle(text(group.title), pageTitle);
    const help = groupHelp?.[group.key];
    return (
      <section
        className={shown ? "group collapse" : "group"}
        key={group.key}
        data-group={group.key}
        data-open={shown && open ? "" : undefined}
      >
        <div className={shown ? "collapse-body" : undefined}>
          {title && (help ? <GroupHeader title={title} help={help} /> : <h3 className="group-title">{title}</h3>)}
          <div className="rows">
            {rows.map((row) =>
              shown ? (
                <SearchSlot
                  key={row.key}
                  row={row}
                  open={shown.has(row.key)}
                  drawn={mounted?.has(row.key) ?? true}
                  // A row outside the filter highlights nothing, so its props stay equal and it
                  // skips the keystroke's render.
                  query={shown.has(row.key) ? query : undefined}
                />
              ) : (
                <Fragment key={row.key}>
                  <SettingRow row={row} query={query} focused={row.key === focus} />
                  {/* The menus keep the launch language: a Relaunch row under Language while they differ. */}
                  {row.key === APP_LANGUAGE_KEY && <LanguageRelaunchRow />}
                </Fragment>
              ),
            )}
            {/* The card's More Options row and the rows it opens (rowLevels.ts). */}
            {!shown && proposed.more && proposed.more.length > 0 && <MoreOptions rows={proposed.more} focus={focus} />}
          </div>
        </div>
      </section>
    );
  });
}

/**
 * A row's slot in the search results: open while the row matches, collapsed in place while it does
 * not; its editor draws once the row has matched. Its props are the row and three plain values, so a
 * keystroke draws only the slots whose match or highlight changed.
 */
const SearchSlot = memo(function SearchSlot({
  row,
  open,
  drawn,
  query,
}: {
  row: SchemaRow;
  open: boolean;
  drawn: boolean;
  query: string | undefined;
}) {
  return (
    <div className="collapse" data-open={open ? "" : undefined}>
      <div className="collapse-body">{drawn && <SettingRow row={row} query={query} filtered={!open} />}</div>
    </div>
  );
});
