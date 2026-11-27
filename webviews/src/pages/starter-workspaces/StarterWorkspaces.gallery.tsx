// l10n-allow-file: gallery fixtures (sample starters), not shipped UI yet.
// Starter workspaces on Home: a first run, then after picking a repo, then with one opened.
import { componentEntry } from "../../gallery/format";
import { StarterWorkspaces, type Starter } from "./StarterWorkspaces";

const DEMOS: Starter[] = [
  { id: "bug", kind: "demo", title: "Fix a planted bug", detail: "A small TypeScript repo with one failing test. Watch an agent find and fix it.", panes: ["Terminal", "Claude Code"], minutes: 3 },
  { id: "race", kind: "demo", title: "Agents side by side", detail: "Claude Code and Codex on the same task in two splits. Compare the diffs.", panes: ["Claude Code", "Codex", "Diff"], minutes: 5 },
  { id: "review", kind: "demo", title: "Review a pull request", detail: "A sample PR with its diff, a browser preview and a chat about it.", panes: ["Diff", "Browser", "Chat"], minutes: 4 },
  { id: "web", kind: "demo", title: "Build a page live", detail: "A dev server in a terminal, the page in a browser split, an agent editing it.", panes: ["Terminal", "Browser", "Claude Code"], minutes: 5 },
];
const PERSONAL: Starter[] = [
  { id: "p-test", kind: "personal", title: "Fix a failing test", detail: "3 tests fail on main. Chief opens one with the log and an agent ready.", panes: ["Terminal", "Claude Code"] },
  { id: "p-explain", kind: "personal", title: "Explain this codebase", detail: "A tour of the repo's layout, entry points and how to build it.", panes: ["Chat", "Files"] },
  { id: "p-ci", kind: "personal", title: "Morning CI report", detail: "Every day at 9: what broke overnight, with links.", panes: ["Routine"] },
  { id: "p-issues", kind: "personal", title: "Triage open issues", detail: "Group the 41 open issues and find the real bugs.", panes: ["Chat", "Browser"] },
];

type Fixture = "firstRun" | "withRepo" | "opened";
const FIXTURES: Record<Fixture, { starters: Starter[]; repo?: string }> = {
  firstRun: { starters: DEMOS },
  withRepo: { starters: [...PERSONAL, ...DEMOS], repo: "manaflow-ai/cmux" },
  opened: {
    starters: [...PERSONAL.map((s) => (s.id === "p-test" ? { ...s, opened: true } : s)), ...DEMOS.map((s) => (s.id === "race" ? { ...s, opened: true } : s))],
    repo: "manaflow-ai/cmux",
  },
};

function Stage({ fixture }: { fixture: Fixture }) {
  const noop = () => {};
  return (
    <div style={{ padding: 16 }}>
      <StarterWorkspaces {...FIXTURES[fixture]} onTry={noop} onRemove={noop} onPickRepo={noop} onHide={noop} />
    </div>
  );
}

export default componentEntry<{ fixture: Fixture }>({
  id: "home.starter-workspaces",
  title: "Starter workspaces",
  area: "Home and Chief",
  height: 640,
  widths: { narrow: 390, normal: 640, wide: 900 },
  covers: ["pages/starter-workspaces/StarterWorkspaces.tsx"],
  load: async () => Stage,
  variants: {
    "first-run": { note: "Before a repo is picked: built-in demos, and a row to get starters from your own repo.", props: { fixture: "firstRun" } },
    "with-repo": { note: "After picking a repo: Chief's starters on the real code come first.", props: { fixture: "withRepo" } },
    opened: { note: "Opened starters are tagged Example and offer Remove.", props: { fixture: "opened" } },
  },
});
