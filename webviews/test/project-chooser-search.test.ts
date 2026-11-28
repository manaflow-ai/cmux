// The project chooser's search (projectRepos.ts chooserRows, and shownRepoRows under it and under FolderPopover).
// Each typed letter regrouped every folder by repository and lowercased every project's and member's words again;
// now the grouping is kept per projects list and the words per project and per group. Correctness: the old
// functions (chooserRowsScan, shownRepoRowsScan) are the oracle on random projects and queries. Speed: a query typed
// letter by letter at 1,100 and 11,000 projects, old against new, interleaved in one process.
import { describe, expect, test } from "bun:test";
import {
  chooserRows,
  chooserRowsScan,
  groupByRepo,
  type ProjectRepo,
  shownRepoRows,
  shownRepoRowsScan,
} from "../src/agent-session/acpmux/projectRepos";
import { expectGrowth, expectSpeedup, forSeeds, type Gen } from "./support/dsaBench";

type Project = { cwd: string; label: string; repo?: ProjectRepo; peer?: string; host?: string };

const NAMES = ["cmux", "Atlas", "web", "ÉCOLE", "straße", "repo", "Lane", "next-reds", "fix-login", "İstanbul"];
const ROOTS = ["/Users/sample/Projects", "/Users/sample/wt/lanes", "/srv", "/Users/sample/scratch", "/Users/sample"];

function randomProjects(g: Gen): Project[] {
  const repos = Array.from({ length: g.int(1, 5) }, (_, i): ProjectRepo => {
    const name = `${g.pick(NAMES)}${i}`;
    const root = `${g.pick(ROOTS)}/${name}`;
    return { root, name, ...(g.bool() ? { github: `Acme/${name}` } : {}), ...(g.bool() ? { branch: "main" } : {}) };
  });
  return Array.from({ length: g.int(0, 25) }, (_, i): Project => {
    const label = `${g.pick(NAMES)}${g.bool(0.3) ? ` ${g.pick(NAMES)}` : ""}`;
    const repo = g.bool(0.6) ? g.pick(repos) : undefined;
    const cwd = repo
      ? g.bool(0.4)
        ? repo.root
        : `${g.bool() ? repo.root : g.pick(ROOTS)}/${label.replaceAll(" ", "-")}${i}`
      : g.bool(0.15)
        ? "/Users/sample"
        : `${g.pick(ROOTS)}/${label.replaceAll(" ", "-")}${i}`;
    const linked = repo && cwd !== repo.root && g.bool() ? { ...repo, top: cwd, branch: `lane/${label}${i}` } : repo;
    const peer = g.bool(0.15) ? `box${g.int(0, 2)}` : undefined;
    return {
      cwd,
      label,
      ...(linked ? { repo: linked } : {}),
      ...(peer ? { peer, host: peer } : g.bool(0.3) ? { host: "This-Mac" } : {}),
    };
  });
}

function randomQuery(g: Gen, projects: readonly Project[]): string {
  if (g.bool(0.15)) return g.pick(["", "  ", " \t "]);
  const word = () => {
    const source = projects.length > 0 && g.bool(0.7) ? g.pick(projects) : undefined;
    const text = source ? g.pick([source.label, source.cwd, source.host ?? "x"]) : g.pick(NAMES);
    const from = g.int(0, Math.max(0, text.length - 1));
    const part = text.slice(from, from + g.int(1, 6));
    return g.bool(0.3) ? part.toUpperCase() : part;
  };
  return Array.from({ length: g.int(1, 3) }, word).join(g.pick([" ", "  "]));
}

/// A realistic chooser: a tenth of the folders are repositories' main checkouts, the rest their lanes' worktrees.
function fixture(count: number): Project[] {
  const repos = Math.ceil(count / 10);
  return Array.from({ length: count }, (_, i) => {
    const r = i % repos;
    const w = Math.floor(i / repos);
    const root = `/Users/dev/Projects/Repo${r}`;
    const cwd = w === 0 ? root : `/Users/dev/wt/lanes/lane-${w}/Repo${r}`;
    return {
      cwd,
      label: w === 0 ? `Repo${r}` : `lane-${w}`,
      host: "this-mac",
      repo: { root, name: `Repo${r}`, github: `acme/repo${r}`, top: cwd, branch: w === 0 ? "main" : `lane/fix-${w}` },
    };
  });
}

/// Typing a query letter by letter, as the search field calls the chooser.
const typing = (rows: (query: string) => unknown, query: string) => () => {
  for (let end = 1; end <= query.length; end++) rows(query.slice(0, end));
};

describe("project chooser search", () => {
  test("chooserRows lists what the old scan lists, in its order, on random projects and queries", () => {
    forSeeds(600, (g) => {
      const projects = randomProjects(g);
      const current = g.bool(0.3) && projects.length > 0 ? g.pick(projects).cwd : undefined;
      // Several queries on one list: the kept grouping and words are reused across them, as while typing.
      for (let q = 0; q < 4; q++) {
        const query = randomQuery(g, projects);
        expect(chooserRows(projects, query, current)).toEqual(chooserRowsScan(projects, query, current));
      }
      // Another current on the same list regroups.
      const other = projects.length > 0 ? g.pick(projects).cwd : undefined;
      expect(chooserRows(projects, "", other)).toEqual(chooserRowsScan(projects, "", other));
    });
  });

  test("shownRepoRows matches the old scan on random groups, queries and expanded repositories", () => {
    forSeeds(600, (g) => {
      const folders = randomProjects(g).map((p) => ({
        id: p.cwd,
        label: p.label,
        ...(p.repo ? { repo: p.repo } : {}),
      }));
      const groups = groupByRepo(folders, undefined, g.bool() ? "main" : undefined);
      const expanded = new Set(groups.filter(() => g.bool(0.3)).map((group) => group.key));
      for (let q = 0; q < 4; q++) {
        const query = randomQuery(
          g,
          folders.map((f) => ({ cwd: f.id, label: f.label })),
        );
        const got = shownRepoRows(groups, query, expanded);
        const want = shownRepoRowsScan(groups, query, expanded);
        expect(got.length).toBe(want.length);
        got.forEach((row, i) => {
          expect(row.group).toBe(want[i]!.group);
          expect(row.worktrees).toEqual(want[i]!.worktrees);
        });
      }
    });
  });

  for (const count of [1_100, 11_000]) {
    test(`typing "repo1 lane" over ${count.toLocaleString("en-US")} projects: faster than the scan`, () => {
      const projects = fixture(count);
      expectSpeedup(
        `chooserRows.typing_${count}`,
        count,
        typing((query) => chooserRowsScan(projects, query), "repo1 lane"),
        typing((query) => chooserRows(projects, query), "repo1 lane"),
        { minSpeedup: 2, budgetMs: count === 1_100 ? 15 : 150, runs: 7 },
      );
    });
  }

  test("one letter's cost when the projects grow 10x: linear in the projects searched, never worse", () => {
    // A search reads every project's words, so a letter is O(projects): ~10x at 10x is expected, not flat. What the
    // change takes out is the regrouping and lowercasing per letter (each a larger constant than the match itself).
    expectGrowth(
      "chooserRows.letter",
      1_100,
      (count) => {
        const projects = fixture(count);
        chooserRows(projects, "r");
        return () => chooserRows(projects, "repo1");
      },
      { maxRatio: 20, runs: 15 },
    );
  });
});
