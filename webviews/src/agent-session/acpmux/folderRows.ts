import { githubFolderRepo } from "./githubRepos";

/// A run of the list's rows that stays together: a repository's rows, an added repository, a machine folder. `ids`:
/// the folders it stands for (a repository's every member, shown or folded), which name it across a late change of
/// its repository's details.
export type RowBlock = { key: string; rows: string[]; ids: string[] };

/// The rows the menu showed at its first paint with rows: each folder's place, the rows themselves, and the folded or
/// opened repositories they were drawn with.
export type ShownRows = { places: ReadonlyMap<string, number>; rows: ReadonlySet<string>; folds: unknown };

export function shownRows(blocks: readonly RowBlock[], folds: unknown): ShownRows {
  const places = new Map<string, number>();
  blocks.forEach((block, at) => block.ids.forEach((id) => places.has(id) || places.set(id, at)));
  return { places, rows: new Set(blocks.flatMap((block) => block.rows)), folds };
}

/// The list as `kept` showed it, while the menu stays open with nothing typed (cmux#53226: rows moved under the
/// pointer as chats, folders and repositories arrived or re-sorted, and the menu grows up from its chip, so even a row
/// added at the end moved every row above it). Each block keeps its place and its rows, found by its folders, so a
/// repository whose details arrive late is the same block. Its lead row is always the live one: a main checkout that
/// arrives under an open repository's listed worktrees leads it, with its disclosure, and the rows under it move down
/// one (the repository's row is the main checkout's, cmux#53226); its other rows keep their shown order. A block that arrives later waits for the next
/// open, except the current folder's (listed after the kept ones); a block that went away leaves.
export function keptRows(kept: ShownRows, blocks: readonly RowBlock[], current: string | undefined): string[] {
  const placed: { at: number; rows: string[] }[] = [];
  const late: string[] = [];
  const keptOrder = new Map([...kept.rows].map((row, index) => [row, index]));
  blocks.forEach((block) => {
    let at: number | undefined;
    for (const id of block.ids) {
      const place = kept.places.get(id);
      if (place !== undefined && (at === undefined || place < at)) at = place;
    }
    if (at === undefined) {
      if (current !== undefined && block.ids.includes(current)) late.push(...block.rows);
      return;
    }
    // The live lead first (it carries the repository's disclosure), then the other rows as they were shown.
    const [lead, ...rest] = block.rows;
    const others = rest.filter((row) => keptOrder.has(row)).sort((a, b) => keptOrder.get(a)! - keptOrder.get(b)!);
    placed.push({ at, rows: lead === undefined ? others : [lead, ...others] });
  });
  placed.sort((left, right) => left.at - right.at);
  return [...placed.flatMap((block) => block.rows), ...late];
}

/// The one place a location's icon is chosen: GitHub's mark only for a repository from the GitHub connection
/// (`github:owner/name`), which is no folder here. Any folder on this Mac, or on a Cloud machine, is a folder: a
/// clone or a worktree whose `origin` is on GitHub too (cmux#53226).
export function isGitHubLocation(location: string | undefined): boolean {
  return githubFolderRepo(location) !== undefined;
}
