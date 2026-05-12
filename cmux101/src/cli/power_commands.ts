/**
 * Power slash commands for cmux101.
 *
 * These commands transform the user's input into a structured prompt that is
 * forwarded to the model instead of the raw user text. They set consumed=true
 * and provide a transformedPrompt so app.tsx sends the structured text to the
 * model rather than the original input.
 */

import type { SlashCommand, SlashContext, SlashResult } from "./slash.js";

// ---------------------------------------------------------------------------
// /ultraplan <topic>
// ---------------------------------------------------------------------------

const ultraplanCommand: SlashCommand = {
  name: "ultraplan",
  description: "Enter deep-planning mode. Produces a structured step-by-step plan for the given topic without executing any tools.",
  async run(_ctx: SlashContext, args: string): Promise<SlashResult> {
    const userInput = args.trim() || "(no topic provided)";
    const transformedPrompt = `You are entering deep-planning mode. The user wants:

${userInput}

Produce a structured plan in this format:
- Step 1: <action>
  - Reasoning: <why>
  - Expected outcome: <what>
- Step 2: ...
- Step N: ...

Then conclude with:
- Risks: <bulleted list>
- Open questions: <bulleted list>
- Suggested next action: <one sentence>

Do not actually execute any tools yet — produce the plan first.`;

    return { consumed: true, transformedPrompt };
  },
};

// ---------------------------------------------------------------------------
// /teleport <target>
// ---------------------------------------------------------------------------

const teleportCommand: SlashCommand = {
  name: "teleport",
  description: "Jump to a file, symbol, or path in the codebase. Usage: /teleport <target>",
  async run(_ctx: SlashContext, args: string): Promise<SlashResult> {
    const target = args.trim() || "(no target provided)";
    const transformedPrompt = `Jump to "${target}". Use the available tools to:
1. Search the codebase for matching file paths and symbols (use glob/grep)
2. If exactly one match, file_read it and return the relevant section
3. If multiple matches, list top 5 candidates with one-line summaries

Be efficient — at most 3-4 tool calls total.`;

    return { consumed: true, transformedPrompt };
  },
};

// ---------------------------------------------------------------------------
// /bughunter [scope]
// ---------------------------------------------------------------------------

const bughunterCommand: SlashCommand = {
  name: "bughunter",
  description: "Scan for bugs, anti-patterns, and code smells. Usage: /bughunter [scope]",
  async run(_ctx: SlashContext, args: string): Promise<SlashResult> {
    const scope = args.trim() || "current directory";
    const transformedPrompt = `You are in bug-hunting mode. Scope: ${scope}.

1. Use glob to find source files (exclude tests, node_modules, dist, build)
2. Use grep to scan for anti-patterns:
   - "TODO|FIXME|HACK|XXX|BUG" markers
   - Empty catch blocks: catch.*\\{\\s*\\}
   - Console.log left in production code
   - unwrap() in Rust, ! assertions in TypeScript
   - any/unknown without a comment
3. For each finding, output: <path>:<line> <one-line description> <severity: low|med|high>
4. Group by file at the end. Limit to top 20 findings.

Be efficient. Don't read whole files — use grep results directly.`;

    return { consumed: true, transformedPrompt };
  },
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createPowerCommands(): SlashCommand[] {
  return [ultraplanCommand, teleportCommand, bughunterCommand];
}
