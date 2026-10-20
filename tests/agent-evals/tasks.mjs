// The agent-evals task set (plans/cmux-next/agent-evals-DESIGN.md).
// `setup` steps are run by the runner before the agent starts:
//   { op: "split-right", alias, name?, run? }   new column right of the origin
//   { op: "tab", pane, alias?, name, run? }      new terminal tab in a pane alias
//   { op: "workspace", name }                    new workspace (focus returns to origin)
// After setup the origin workspace and pane are focused again.
// Prompts never say how to use cmux: finding the CLI or tools is part of the test.

const req = (check, params) => ({ check, params, required: true });
const bonus = (check, params) => ({ check, params, required: false });

/** Checks every task carries: stay in the eval session, keep focus, close nothing. */
const COMMON = [req("stayed_in_session"), req("focus_kept"), req("user_tabs_kept")];
const NO_NEW_WS = req("no_new_workspaces");

/** A new terminal placed right of the user, as a tab, without extra splits. */
const PLACED_RIGHT = (count, maxColumns = 1) => [
  req("new_tabs", { count, kind: "terminal" }),
  req("new_tabs_right_of_origin"),
  req("not_docked"),
  req("columns_added_at_most", { n: maxColumns }),
];

export const TASKS = Object.freeze([
  {
    id: "terminal-right",
    tier: "headless",
    prompt:
      "Open a new terminal on the right side of my screen and run `echo EVAL_RIGHT_OK` in it. " +
      "Keep me where I am.",
    setup: [],
    checks: [...PLACED_RIGHT(1), req("terminal_text_contains", { text: "EVAL_RIGHT_OK", output_line: true }), ...COMMON, NO_NEW_WS],
  },
  {
    id: "watch-command",
    tier: "headless",
    prompt:
      "Run `echo EVAL_WATCH_OK` in a separate terminal that I can watch while I keep working here.",
    setup: [],
    checks: [...PLACED_RIGHT(1), req("terminal_text_contains", { text: "EVAL_WATCH_OK", output_line: true }), ...COMMON, NO_NEW_WS],
  },
  {
    id: "reuse-right",
    tier: "headless",
    prompt:
      "Open another terminal next to my logs on the right and run `echo EVAL_REUSE_OK` in it.",
    setup: [{ op: "split-right", alias: "right", name: "logs", run: "echo tailing logs" }],
    checks: [
      req("new_tabs", { count: 1, kind: "terminal" }),
      req("new_tabs_in_pane", { pane: "right" }),
      req("columns_added_at_most", { n: 0 }),
      req("terminal_text_contains", { text: "EVAL_REUSE_OK", output_line: true }),
      ...COMMON,
      NO_NEW_WS,
    ],
  },
  {
    id: "subagents-right",
    tier: "headless",
    prompt:
      "Start three helper agents: `cmux-eval-agent --role build`, `cmux-eval-agent --role test` and " +
      "`cmux-eval-agent --role lint`. Each one runs in its own terminal tab on the right side, named " +
      "after its role. They keep running, so don't wait for them to finish. When they're up, put the " +
      "three tabs in one tab group.",
    setup: [],
    checks: [
      req("new_tabs", { count: 3, kind: "terminal" }),
      req("new_tabs_right_of_origin"),
      req("not_docked"),
      req("columns_added_at_most", { n: 1 }),
      req("markers_present", { roles: ["build", "test", "lint"] }),
      req("tab_names_cover", { words: ["build", "test", "lint"] }),
      req("tab_group_exact"),
      ...COMMON,
      NO_NEW_WS,
    ],
  },
  {
    id: "group-workspaces",
    tier: "headless",
    prompt:
      "My sidebar is messy. Put related workspaces into workspace groups. Don't close, rename or " +
      "switch to anything.",
    setup: [
      { op: "workspace", name: "api: server" },
      { op: "workspace", name: "web: landing page" },
      { op: "workspace", name: "api: migrations" },
      { op: "workspace", name: "web: dashboard" },
    ],
    checks: [
      req("workspaces_grouped_together", { names: ["api: server", "api: migrations"] }),
      req("workspaces_grouped_together", { names: ["web: landing page", "web: dashboard"] }),
      req("workspaces_grouped_apart", { a: "api: server", b: "web: dashboard" }),
      req("workspaces_kept"),
      bonus("group_name_matches", { kind: "workspace", members: ["api: server"], words: ["api", "backend", "server"] }),
      bonus("group_name_matches", { kind: "workspace", members: ["web: dashboard"], words: ["web", "frontend", "site"] }),
      ...COMMON,
      NO_NEW_WS,
    ],
  },
  {
    id: "group-tabs",
    tier: "headless",
    prompt: "Group the tabs on my right into sensible tab groups. Don't close anything.",
    setup: [
      { op: "split-right", alias: "right", name: "server" },
      { op: "tab", pane: "right", name: "unit tests" },
      { op: "tab", pane: "right", name: "server logs" },
      { op: "tab", pane: "right", name: "test watcher" },
      { op: "tab", pane: "right", name: "git status" },
    ],
    checks: [
      req("tabs_grouped_together", { names: ["server", "server logs"] }),
      req("tabs_grouped_together", { names: ["unit tests", "test watcher"] }),
      req("tabs_grouped_apart", { a: "server", b: "unit tests" }),
      bonus("group_name_matches", { kind: "tab", members: ["server"], words: ["server", "backend", "app", "run"] }),
      bonus("group_name_matches", { kind: "tab", members: ["unit tests"], words: ["test"] }),
      ...COMMON,
      NO_NEW_WS,
    ],
  },
  {
    id: "read-only-answer",
    tier: "headless",
    prompt:
      "The build in the terminal on my right failed. What error code did it print? Don't change " +
      "anything in my layout.",
    setup: [{ op: "split-right", alias: "right", name: "build", run: "echo 'BUILD FAILED: error E4271 in parser.rs:88'" }],
    checks: [req("answer_contains", { text: "E4271" }), req("layout_unchanged"), ...COMMON],
  },
  {
    id: "new-workspace-background",
    tier: "headless",
    prompt:
      "Set up a new workspace called eval-proj with two terminals side by side, and run " +
      "`echo EVAL_WS_OK` in the right one. Don't switch me to it.",
    setup: [],
    checks: [
      req("new_workspaces", { count: 1, name: "eval-proj" }),
      req("workspace_side_by_side", { name: "eval-proj", text: "EVAL_WS_OK" }),
      ...COMMON,
    ],
  },
  {
    id: "organize-end-to-end",
    tier: "headless",
    prompt:
      "Run `echo EVAL_FE_OK` and `echo EVAL_BE_OK` in two new terminals on my right. Then tidy up: " +
      "put those two in a tab group, and put this workspace in a workspace group for the 'shop' project.",
    setup: [],
    checks: [
      ...PLACED_RIGHT(2),
      req("terminal_text_contains", { text: "EVAL_FE_OK", output_line: true }),
      req("terminal_text_contains", { text: "EVAL_BE_OK", output_line: true }),
      req("tab_group_exact"),
      req("workspace_in_group", { workspace: "origin", words: ["shop"] }),
      ...COMMON,
      NO_NEW_WS,
    ],
  },
  // App tier: needs a cmux-next app that owns the eval session (fleet GUI Mac).
  {
    id: "browser-right",
    tier: "app",
    prompt: "Open {fixture}/ in a browser on my right.",
    setup: [],
    checks: [req("new_tabs", { count: 1, kind: "browser" }), req("new_tabs_right_of_origin"), req("not_docked"), req("columns_added_at_most", { n: 1 }), ...COMMON, NO_NEW_WS],
  },
  {
    id: "markdown-right",
    tier: "app",
    prompt: "Open {workdir}/notes/PLAN.md so I can read it next to me.",
    setup: [],
    checks: [req("new_tabs", { count: 1 }), req("new_tabs_right_of_origin"), req("not_docked"), req("columns_added_at_most", { n: 1 }), ...COMMON, NO_NEW_WS],
  },
  {
    id: "website-form",
    tier: "app",
    prompt: "On {fixture}/signup, sign me up as Ada Lovelace with the Pro plan. Use the cmux browser on my right.",
    setup: [],
    checks: [req("new_tabs", { min: 1, kind: "browser" }), req("new_tabs_right_of_origin"), ...COMMON, NO_NEW_WS],
    server_check: { path: "/signup", body: { name: "Ada Lovelace", plan: "pro" } },
  },
  {
    id: "website-read",
    tier: "app",
    prompt: "Open {fixture}/order in the cmux browser and tell me the order total.",
    setup: [],
    checks: [req("answer_contains", { text: "1,284.50" }), req("new_tabs_right_of_origin"), ...COMMON, NO_NEW_WS],
  },
  {
    id: "research-group",
    tier: "app",
    prompt:
      "Open {fixture}/a, {fixture}/b and {fixture}/c in the browser on my right and group the three " +
      "tabs, since they're research for the same thing.",
    setup: [],
    checks: [req("new_tabs", { count: 3, kind: "browser" }), req("new_tabs_right_of_origin"), req("tab_group_exact"), ...COMMON, NO_NEW_WS],
  },
]);
