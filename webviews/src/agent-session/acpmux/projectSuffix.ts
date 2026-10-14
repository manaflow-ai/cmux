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
export function projectSuffixes(projects: readonly Named[]): Map<string, string> {
  const groups = new Map<string, Named[]>();
  for (const project of projects) {
    const key = project.label.toLowerCase();
    groups.set(key, [...(groups.get(key) ?? []), project]);
  }
  const suffixes = new Map<string, string>();
  for (const group of groups.values()) {
    const folders = new Map(group.map((project) => [project.cwd, ownFolders(project)]));
    const paths = new Set(group.map((project) => normalize(project.cwd)));
    if (paths.size < 2) continue;
    for (const project of group) {
      const own = folders.get(project.cwd)!;
      const others = group.filter((other) => normalize(other.cwd) !== normalize(project.cwd));
      let suffix: string | undefined;
      for (let depth = 1; depth <= own.length && suffix === undefined; depth++) {
        const tail = own.slice(-depth).join("/");
        if (others.every((other) => folders.get(other.cwd)!.slice(-depth).join("/") !== tail)) suffix = tail;
      }
      suffixes.set(project.cwd, suffix ?? parentFolder(project.cwd));
    }
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
