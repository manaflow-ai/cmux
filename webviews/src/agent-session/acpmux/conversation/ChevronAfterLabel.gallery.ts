// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// Every transcript disclosure chevron right after its label's words, the way ChatGPT draws "Worked
// for 11s ⌄" (Leo, 2026-11-03: "this how chatgpt does their chevrons"): small, muted, pointing down
// while closed and up while open, never parked at the row's far edge. The variants try the glyph's
// size and its gap after the words (conversation.css --cv-chevron-glyph and --cv-chevron-gap); the
// selected one is the default. A narrow width shows a cut label keeping its chevron after the
// ellipsis. test/transcript-chevron-after-label.test.ts measures the shipped rows.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  thought,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });

const SENDER = "lane-box-2/cloud-promote";
const RECEIVED =
  "backend.yml is green at 4f2a91c, the candidate is ready to promote whenever the production window opens again.";

const snapshot = () => {
  const base = chat(
    [
      user("Promote the candidate once backend.yml is green on the lane.", 20),
      activity(
        [
          thought("Check the lane's last backend.yml run before dispatching anything."),
          run("Read the lane's last run", "gh run list -w backend.yml -L 1"),
          run("Read the candidate's sha", "git rev-parse --short HEAD"),
        ],
        19.9,
      ),
      assistant("The lane's run is still going; I'll wait for it and then promote.", 19.8),
      summary(19.7, { status: "completed", durationMs: 11_000, toolCount: 2 }),
      user(RECEIVED, 12, {
        incoming: {
          kind: "message",
          message: { name: SENDER, text: RECEIVED, raw: RECEIVED, sessionId: "s-lane", harness: "claude" },
        },
        untyped: true,
      }),
      row(BACKGROUND_TURN, 8, {
        id: backgroundTurnRowId("chevrons-scheduled"),
        background: { id: "chevrons-scheduled", trigger: "scheduled", running: false, quiet: true },
      }),
      activity([run("Read the lane's last run", "gh run list -w backend.yml -L 1")], 7.9, {
        inBackground: "chevrons-scheduled",
      }),
      assistant("Nothing new yet.", 7.8, { inBackground: "chevrons-scheduled" }),
      activity(
        [
          run("Check backend.yml dispatch inputs", "gh workflow view backend.yml --yaml"),
          run("Dispatch production promote of the candidate", "gh workflow run backend.yml -f env=production"),
        ],
        4,
        { id: "chevrons-run" },
      ),
    ],
    {
      title: "cloud-promote",
      sessions: [
        session({ sessionId: SESSION_ID, title: "cloud-promote", name: "cloud-promote" }),
        session({ sessionId: "s-lane", title: SENDER, name: SENDER }),
      ],
    },
  );
  return { ...base, summary: { ...base.summary!, family: "claude" } };
};

const STYLE_ID = "gallery-chevron-after-label";

/// Sets the chevron's glyph size and gap, then opens the last "Ran 2 commands" (its steps show the
/// hover chevron after their labels).
const look =
  (glyph?: string, gap?: string): Play =>
  async (ctx) => {
    ctx.document.getElementById(STYLE_ID)?.remove();
    if (glyph || gap) {
      const style = ctx.document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = `:root { ${glyph ? `--cv-chevron-glyph: ${glyph};` : ""} ${gap ? `--cv-chevron-gap: ${gap};` : ""} }`;
      ctx.document.head.append(style);
    }
    const line = () =>
      [...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool[aria-expanded]")].filter((node) =>
        /Ran 2 commands/.test(node.textContent ?? ""),
      )[0];
    await ctx.waitFor(line, { capMs: 10_000 });
    if (line()?.getAttribute("aria-expanded") === "false") line()!.click();
    await ctx.waitFor(() => ctx.document.querySelector(".cv-steps"), { capMs: 10_000 });
  };

const variants: Record<string, AgentPaneVariant> = {
  chatgpt: {
    note: 'Selected default: a 12px glyph whose ink starts 5px after the words, as ChatGPT\'s "Worked for 11s ⌄". Down while closed, up while open.',
    snapshot: snapshot(),
    play: look(),
  },
  tight: {
    note: "A 10px glyph 3px after the words: reads as part of the label, but small at 1x.",
    snapshot: snapshot(),
    play: look("10px", "3px"),
  },
  spaced: {
    note: "A 12px glyph a full word space (8px) after the words: clearly its own control, a little detached.",
    snapshot: snapshot(),
    play: look("12px", "8px"),
  },
  large: {
    note: "A 14px glyph 5px after the words: the tool glyphs' size, heavier than ChatGPT's.",
    snapshot: snapshot(),
    play: look("14px", "5px"),
  },
};

export default agentPaneEntry({
  id: "agent-pane.transcript-chevron-after-label",
  title: "Transcript chevrons: right after the label, pointing down, the ChatGPT way",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/conversation/TranscriptActivityRow.css",
    "agent-session/acpmux/subagents/DisclosureRow.css",
  ],
  variants,
});
