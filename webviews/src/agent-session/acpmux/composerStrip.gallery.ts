// l10n-allow-file: gallery fixtures (sample chats and folders), not shipped UI.
// The composer's location strip (hq#1957 composer location strip, Composer.tsx, ComposerContext.tsx,
// composerLocation.css): the folder, the computer and the branch stand a few px over the card
// instead of a second row inside it, so the card holds one controls row. Only a new chat has
// it, before its first send (locationRow.ts); a started chat's card stands alone, and its queued
// prompts sit on the card. The strip keeps one height with a project, without one and while the
// host's name loads. A new chat's effort chip draws what this harness last showed and its access
// chip the start mode acpmux last answered, never a placeholder (`awaiting` against `reported`).
// test/composer-location-strip.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, noChat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};

const modes = {
  currentModeId: "auto",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
    { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
  ],
};

function started(fields: Parameters<typeof chat>[1] = {}): AcpmuxSnapshot {
  const snapshot = chat(
    [
      user("Add retries with backoff to the fetch helper", 10),
      assistant("Done: GETs retry, POSTs only with a policy.", 9),
      summary(9, { status: "completed" }),
    ],
    { title: "Location strip", ...fields },
  );
  return { ...snapshot, summary: { ...snapshot.summary!, configOptions: [effort], modes } };
}

/// A new chat on Claude: `reported` once its session has reported effort and access.
function fresh(reported: boolean, fields: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}): AcpmuxSnapshot {
  return noChat([], {
    summary: {
      sessionId: reported ? "gallery-new" : "",
      harness: "claude",
      model: "claude-opus-5-5",
      turnCount: 0,
      ...(reported ? { configOptions: [effort], modes } : {}),
      ...fields,
    },
  });
}

export default agentPaneEntry({
  id: "agent-pane.composer-strip",
  title: "Composer location strip",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [
    { selector: ".acpmux-composer-strip" },
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-bar" },
  ],
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext", "agent-session/acpmux/Composer.tsx#Composer"],
  variants: {
    project: {
      note: "A new chat in a project: folder · computer and the branch in the strip on the card's top edge; one controls row in the card.",
      ready: { newSession: true },
      snapshot: fresh(true, { cwd: "/Users/you/src/cmux", branch: "main" }),
    },
    started: {
      note: "After the first send: no location strip (a chat cannot change folder or machine), and no gap where it stood.",
      snapshot: started(),
    },
    "started-movable": {
      note: "A started chat its tab's right-click menu can move (Move to Cloud): still no location strip over the composer; the move stays in that menu.",
      native: { "pane.tabState": { moves: ["cloudMove"] } },
      snapshot: started(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
        if (ctx.document.querySelector(".acpmux-composer-strip"))
          throw new Error("a started chat drew the location strip over its composer");
      },
    },
    "long-folder": {
      note: 'A new chat in a folder with a long name: in a narrow pane it cuts in the middle and keeps its last word ("atlas-we…service"); the branch keeps its name.',
      ready: { newSession: true },
      snapshot: fresh(true, { cwd: "/Users/you/src/atlas-web-checkout-service", branch: "main" }),
    },
    "mid-folder": {
      note: "A new chat in a folder that fits a 341 px pane whole and cuts in the middle at 340, the strip's folder step.",
      ready: { newSession: true },
      snapshot: fresh(true, { cwd: "/Users/you/src/atlas-checkout", branch: "main" }),
    },
    "no-project": {
      note: "A new chat with no folder yet: Choose folder in the strip, which keeps its height.",
      ready: { newSession: true },
      snapshot: fresh(true),
    },
    "host-loading": {
      note: "The host has not named this Mac yet: the strip keeps its height and its place.",
      ready: { newSession: true, machineName: undefined },
      snapshot: fresh(true),
    },
    queued: {
      note: "A running turn with queued prompts: no strip, the queue sits on the card, never over it or the field.",
      snapshot: {
        ...started({ isWorking: true }),
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      },
    },
    awaiting: {
      note: "A new chat before its session reports effort and access: the effort this harness last showed and acpmux's kept start mode, or nothing; never grey bars.",
      ready: { newSession: true },
      snapshot: fresh(false),
    },
    reported: {
      note: "The same new chat once its session reported: the chips take the places they held.",
      ready: { newSession: true },
      snapshot: fresh(true),
    },
  },
});
