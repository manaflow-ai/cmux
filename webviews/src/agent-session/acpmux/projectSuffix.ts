/// What tells projects with the same name apart in the folder popover (hq#1957 composer location
/// strip): Leo's list showed several rows named "cmux", one per worktree, each with its full path.
/// A name no other project shares gets no suffix. Projects sharing a name (case aside) each take the
/// fewest trailing folders of their path that no other project of that name has at the same depth:
/// a worktree's lane ("cg-lane-adopt"), or lane and folder ("cg-lane-adopt/composer") when the
/// folder is named for its branch while the label is the repo's. The project's own folder is left
/// out when it is the name. The home folder reads `~`. A path whose folders all match the end of
/// another's falls back to its parent folder, written from the root (or `~`).

type Named = { readonly cwd: string; readonly label: string };

/// Each ambiguous project's suffix, keyed by its `cwd` as given. Unique names are absent.
///
/// One pass per depth over a name's projects, counting the paths each tail is the end of: a tail
/// only its own path has tells it apart. Comparing each project with every other one of its name
/// was the square of that count: Leo's chats at 10K sessions named 4,000 folders, most of them
/// worktrees named "cmux", and the New Tab pages' folder menus and the composer's folder list ran
/// it on each change of any chat until a key waited seconds (Leo 2026-11-18, "typing in the
/// composer still slow 😞 there must be a lot of open stuff?"; bench/session-scale-typing.bench.ts).
export function projectSuffixes(projects: readonly Named[]): Map<string, string> {
  const groups = new Map<string, Named[]>();
  for (const project of projects) {
    const key = project.label.toLowerCase();
    const group = groups.get(key);
    if (group) group.push(project);
    else groups.set(key, [project]);
  }
  const suffixes = new Map<string, string>();
  for (const group of groups.values()) {
    if (group.length < 2) continue;
    const members = group.map((project) => ({ project, path: normalize(project.cwd), own: ownFolders(project) }));
    if (new Set(members.map((member) => member.path)).size < 2) continue;
    const deepest = Math.max(...members.map((member) => member.own.length));
    // Which projects still look for their suffix, and the one each found.
    const found = new Map<(typeof members)[number], string>();
    for (let depth = 1; depth <= deepest && found.size < members.length; depth++) {
      // A tail and the paths whose folders end in it at this depth: a shorter path's tail is all of
      // its folders, as `slice(-depth)` gives.
      const paths = new Map<string, string | null>();
      const tails = members.map((member) => {
        const tail = member.own.slice(-depth).join("/");
        const seen = paths.get(tail);
        if (seen === undefined) paths.set(tail, member.path);
        else if (seen !== null && seen !== member.path) paths.set(tail, null);
        return tail;
      });
      members.forEach((member, at) => {
        if (found.has(member) || depth > member.own.length) return;
        if (paths.get(tails[at]!) !== null) found.set(member, tails[at]!);
      });
    }
    for (const member of members)
      suffixes.set(member.project.cwd, found.get(member) ?? parentFolder(member.project.cwd));
  }
  return suffixes;
}

function normalize(cwd: string): string {
  return cwd.replace(/(.)\/+$/, "$1");
}

/// The home folder as one `~` folder: /Users/me or /home/me.
function homeFolded(cwd: string): string[] {
  const parts = normalize(cwd).split("/").filter(Boolean);
  return (parts[0] === "Users" || parts[0] === "home") && parts.length >= 2 ? ["~", ...parts.slice(2)] : parts;
}

/// The folders that can tell a project apart: its path, less its last folder when that is its name.
function ownFolders(project: Named): string[] {
  const parts = homeFolded(project.cwd);
  return parts.at(-1)?.toLowerCase() === project.label.toLowerCase() ? parts.slice(0, -1) : parts;
}

function parentFolder(cwd: string): string {
  const parts = homeFolded(cwd).slice(0, -1);
  if (parts[0] === "~") return parts.join("/");
  return "/" + parts.join("/");
}
