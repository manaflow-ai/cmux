// How many pull request chips a message's PR row shows, and whether they carry titles
// (PullRequestDock.tsx). A chip is its number alone, or its number and a title long enough to
// read: a title is drawn only when at least `minTitle` of it fits (or all of it, when it is
// shorter), never as a stub of a few letters. The rest sit behind the +N overflow, which lists them.

export type PullRequestChipPlan = {
  /// Chips drawn in the row; the rest are in the overflow list.
  count: number;
  /// Whether the drawn chips show their titles beside their numbers.
  titled: boolean;
  /// Per drawn chip: its whole title is no wider than the readable minimum, so it keeps its own
  /// width instead of the minimum (the same rule pullRequestChipsWidth counts with).
  short: readonly boolean[];
};

export type PullRequestChipSizes = {
  /// The row's width.
  room: number;
  /// The gap between chips (and before the overflow button).
  gap: number;
  /// Each candidate chip's width with its number alone, padding included, in order.
  numbers: readonly number[];
  /// Each candidate chip's title width (its gap before the title included), or 0 with no title.
  titles: readonly number[];
  /// The overflow button's width with `count` chips drawn (`+{total - count}`), at index count - 1.
  more: readonly number[];
  /// The least title width that still reads (about 12 characters).
  minTitle: number;
  /// The most chips the row may draw.
  limit: number;
  /// Every pull request the row holds, drawn or in the overflow.
  total: number;
  /// False draws numbers only (the gallery's numbers-only treatment).
  withTitles?: boolean;
};

/// The width `count` chips take, with titles cut to their readable minimum when `titled`.
export function pullRequestChipsWidth(sizes: PullRequestChipSizes, count: number, titled: boolean): number {
  let width = 0;
  for (let index = 0; index < count; index++) {
    width += sizes.numbers[index] ?? 0;
    const title = sizes.titles[index] ?? 0;
    if (titled && title > 0) width += Math.min(title, sizes.minTitle);
    if (index > 0) width += sizes.gap;
  }
  if (sizes.total > count) width += sizes.gap + (sizes.more[count - 1] ?? sizes.more.at(-1) ?? 0);
  return width;
}

/// The most readable row that fits: titled chips first (the most that fit), then numbers alone,
/// then one number and the overflow. At least one chip always shows.
export function planPullRequestChips(sizes: PullRequestChipSizes): PullRequestChipPlan {
  const most = Math.max(1, Math.min(sizes.limit, sizes.total, sizes.numbers.length));
  const plan = (count: number, titled: boolean): PullRequestChipPlan => ({
    count,
    titled,
    short: sizes.titles.slice(0, count).map((title) => title <= sizes.minTitle),
  });
  if (sizes.withTitles !== false)
    for (let count = most; count >= 1; count--) {
      const anyTitle = sizes.titles.slice(0, count).some((title) => title > 0);
      if (anyTitle && pullRequestChipsWidth(sizes, count, true) <= sizes.room) return plan(count, true);
    }
  for (let count = most; count > 1; count--)
    if (pullRequestChipsWidth(sizes, count, false) <= sizes.room) return plan(count, false);
  return plan(1, false);
}
