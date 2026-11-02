// l10n-allow-file: gallery fixtures (synthetic skill names), not shipped UI.
// The composer's + menu with an agent that advertises many skills (Leo, 2026-11-01: "our + button
// results are still really bad"; his + listed every skill and slash command, off the screen). +
// lists attach, Plan, Goal and Mention, at most three recent commands and one "Commands and
// skills…" row that opens the slash list. Compare arms (`composer-plus-commands`) shows where the
// recents and the row stand; the variants vary the recents a person has.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { composerPlusCommands } from "./composerPlusCommands.experiment";
import type { AcpmuxSnapshot } from "./model";
import type { SlashCommand } from "./slashCommands";

const RECENTS_KEY = "cmux.acpmux.recentSlashCommands";

const SKILLS = [
  "agent-sdk",
  "agents-md",
  "aws-billing",
  "aws-cdk",
  "aws-iam",
  "aws-networking",
  "aws-sdk-js",
  "cloudflare-workers",
  "cloudflare-d1",
  "durable-objects",
  "github-actions",
  "launch-checklist",
  "sandbox",
  "signing",
  "turnstile",
  "web-perf",
  "wrangler",
  "deep-research",
];

const COMMANDS: SlashCommand[] = [
  { name: "goal", description: "Set a goal for this chat", source: "agent" },
  { name: "compact", description: "Clear conversation history but keep a summary in context" },
  { name: "review", description: "Review the current diff" },
  ...SKILLS.map((name) => ({
    name,
    description: `Sample skill: ${name.replace(/-/g, " ")}, with a description past the menu's edge`,
    source: "skill" as const,
  })),
  { name: "cmux:add-lane", description: "Start a lane in cmux", source: "prompt" },
  { name: "cmux:create-pr", description: "Open a pull request from this chat", source: "prompt" },
];

const snapshot: AcpmuxSnapshot = ((base) => ({
  ...base,
  summary: {
    ...base.summary!,
    promptCapabilities: { image: true },
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "plan", name: "Plan" },
      ],
    },
  },
}))(
  chat(
    [
      user("Add retries with backoff to the fetch helper", 10),
      assistant("Done: GETs retry, POSTs only with a policy.", 9),
      summary(9, { status: "completed" }),
    ],
    { commands: COMMANDS },
  ),
);

/** Opens + with `recents` as the person's recent commands (the menu reads them as it opens). */
function openWith(recents: readonly string[]) {
  return async (ctx: PlayContext) => {
    ctx.document.defaultView?.localStorage.setItem(RECENTS_KEY, JSON.stringify(recents));
    await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
    await ctx.waitFor(() => ctx.document.querySelector('.acpmux-composer-plus [data-value="add.commands"]'));
  };
}

function variant(note: string, recents: readonly string[]): AgentPaneVariant {
  return { note, snapshot, native: { "composer.capture": null }, play: openWith(recents) };
}

export default agentPaneEntry({
  id: "agent-pane.composer-plus",
  title: "Composer + menu",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/ComposerPlusMenu.tsx#ComposerPlusMenu"],
  keywords: ["plus", "+", "skills", "commands", "slash", "recent"],
  variants: {
    "recent-commands": variant(
      "Play: + in a chat with 23 skills and commands: attach, Plan, Goal, Mention, the three commands used last, then Commands and skills… (opens /), then the searches.",
      ["review", "aws-cdk", "goal", "cloudflare-workers", "wrangler"],
    ),
    "one-recent": variant("Play: + after one command was used: it, then Commands and skills….", ["compact"]),
    "no-recents": variant(
      "Play: + before any command was used (or none the agent still lists): one Commands and skills… row, no command rows.",
      ["not-advertised-here"],
    ),
  },
  experiment: {
    definition: composerPlusCommands,
    setup: openWith(["review", "aws-cdk", "cloudflare-workers"]),
    script: [
      {
        name: "Highlight Commands and skills…",
        run: async (ctx) => {
          await ctx.hover({ selector: '.acpmux-composer-plus [data-value="add.commands"]' });
        },
      },
    ],
  },
});
