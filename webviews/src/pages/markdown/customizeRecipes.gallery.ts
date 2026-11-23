// l10n-allow-file: gallery fixtures (sample documents), not shipped UI.
// The Customize recipes guide (docs/cmux-next/customize-recipes.md, written into the customize state
// folder by `cmux customize recipes --open`) in the Markdown page, where each recipe's shell block
// gets a Run button: the one-click Try it. Three layouts of the same twelve recipes; the docs page is
// the chosen one ("grouped"). References: extension browsers with one action per item, and Codex's
// automation templates (the wish as an editable starting point).
import { markdownPageEntry } from "../../gallery/format";
import { githubSlug } from "./links";

const DIR = "/Users/you/.local/state/cmux/customize/recipes";

interface Recipe {
  name: string;
  title: string;
  group: "Look" | "Layout" | "Type" | "Widgets" | "Keys" | "App looks";
  line: string;
  ask: string;
}

// The same twelve as cmux-customize-recipes' RECIPES, in the guide's order.
const RECIPES: Recipe[] = [
  {
    name: "tiling-look",
    title: "A tiling window manager look",
    group: "Look",
    line: "Hard pane borders, small gaps, a rail sidebar, no motion.",
    ask: "make it look like a tiling window manager",
  },
  {
    name: "calm",
    title: "Calm: no motion",
    group: "Look",
    line: "Nothing slides, pulses or blinks, and status is quieter.",
    ask: "turn off the animations and make it calm",
  },
  {
    name: "glass",
    title: "Glass",
    group: "Look",
    line: "See-through glass behind the window, with a lighter sidebar.",
    ask: "make the window see-through glass",
  },
  {
    name: "compact-sidebar",
    title: "A compact sidebar",
    group: "Layout",
    line: "A narrower sidebar with shorter rows. Its buttons show when you point at it.",
    ask: "make the sidebar compact",
  },
  {
    name: "vertical-tabs",
    title: "Vertical tabs",
    group: "Layout",
    line: "Tabs in a column beside the panes instead of a strip above them.",
    ask: "put my tabs in a vertical list",
  },
  {
    name: "different-font",
    title: "A different font",
    group: "Type",
    line: "Geist in the chats, Menlo in the terminal and the editor, a serif for Markdown pages.",
    ask: "use Geist in the chats and Menlo for code",
  },
  {
    name: "larger-text",
    title: "Larger text",
    group: "Type",
    line: "Bigger text in the sidebar, the chats, the terminal and Markdown pages.",
    ask: "make the text bigger everywhere",
  },
  {
    name: "pr-widget",
    title: "Your pull requests in the sidebar",
    group: "Widgets",
    line: "Your open pull requests and the reviews you owe, live in the sidebar.",
    ask: "add a PR widget to the sidebar",
  },
  {
    name: "clock-weather",
    title: "The time and the weather",
    group: "Widgets",
    line: "The time and the weather where you are, at the bottom of the sidebar.",
    ask: "show the time and the weather in the sidebar",
  },
  {
    name: "pane-keys",
    title: "Move between panes with H J K L",
    group: "Keys",
    line: "Control-Command-H, J, K and L move between panes, like Vim.",
    ask: "let me move between panes with ctrl-cmd-h, j, k and l",
  },
  {
    name: "codex-app",
    title: "Like the Codex app",
    group: "App looks",
    line: "A gray sidebar of your chats by project, a white page, your prompts in gray pills, a large rounded composer.",
    ask: "make cmux look and work like the Codex app",
  },
  {
    name: "claude-code-app",
    title: "Like the Claude desktop app",
    group: "App looks",
    line: "A #191919 page, a warm sidebar of sessions by project, a one-line composer, your prompt in a #252525 pill.",
    ask: "make cmux look and work like the Claude desktop app's Code tab",
  },
];

const GROUPS = ["Look", "Layout", "Type", "Widgets", "Keys", "App looks"] as const;

const INTRO = `# Customize recipes

Twelve ready-made changes to cmux. Press **Run** on a recipe's command to try it: cmux changes at
once, as a preview. Nothing is kept until you apply it.

- Keep it: \`cmux customize apply\`
- Put back what you had: \`cmux customize discard\`
- Change your mind later: \`cmux customize rollback\`
`;

const tryBlock = (recipe: Recipe) => "```sh\ncmux customize use " + `${DIR}/${recipe.name}.json` + "\n```\n";

// Chosen: grouped by what it changes; each recipe a heading, one line, its Run block and the wish.
const GROUPED = [
  INTRO,
  ...GROUPS.map(
    (group) =>
      `## ${group}\n\n` +
      RECIPES.filter((recipe) => recipe.group === group)
        .map((recipe) => `### ${recipe.title}\n\n${recipe.line}\n\n${tryBlock(recipe)}\nOr ask: "${recipe.ask}"\n`)
        .join("\n"),
  ),
].join("\n");

// A flat list: no groups, every recipe at the same level, in the same order.
const FLAT = [
  INTRO,
  ...RECIPES.map((recipe) => `## ${recipe.title}\n\n${recipe.line}\n\n${tryBlock(recipe)}\nOr ask: "${recipe.ask}"\n`),
].join("\n");

// An index table first (what, the wish), then the Run blocks under one heading each.
const TABLE = [
  INTRO,
  "## The recipes\n\n| Recipe | Changes | Or ask |\n| --- | --- | --- |\n" +
    RECIPES.map(
      (recipe) => `| [${recipe.title}](#${githubSlug(recipe.title)}) | ${recipe.group} | "${recipe.ask}" |`,
    ).join("\n") +
    "\n",
  "## Try one\n",
  ...RECIPES.map((recipe) => `### ${recipe.title}\n\n${tryBlock(recipe)}`),
].join("\n");

const PATH = `${DIR}/README.md`;

export default markdownPageEntry({
  id: "pages.customize-recipes",
  title: "Customize recipes guide",
  area: "Pages",
  height: 720,
  covers: ["page:cmux.markdown", "pages/markdown/MarkdownPage.tsx", "pages/markdown/runButtons.ts"],
  variants: {
    grouped: {
      note: "Chosen version: grouped by what it changes (Look, Layout, Type, Widgets, Keys, App looks); each recipe has one line, its Run block (Try it) and the wish to ask instead. Twelve Run buttons, one per recipe, and the groups keep a long page scannable.",
      path: PATH,
      text: GROUPED,
    },
    flat: {
      note: "Comparison: every recipe at the same level, no groups. Shorter outline, but twelve same-weight sections read as one long list.",
      path: PATH,
      text: FLAT,
    },
    table: {
      note: "Comparison: an index table first, the Run blocks below. Scans fastest, but Try it sits away from the line that says what the recipe does.",
      path: PATH,
      text: TABLE,
    },
  },
});
