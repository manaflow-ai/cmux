// l10n-allow-file: gallery fixtures (prompts, subagent names, commands, chat titles), not shipped UI.
// Running subagents, background commands and chats the agent started in one tray at the foot of
// the chat, right above the composer (SubagentTray.tsx, runningTray.ts), never in the middle of
// history, in a turn and after it ("Running in background · …"): one running is its line alone;
// several get a header ("3 subagents running · 1 command") with a line each; past three they start
// folded to the header. The transcript has no "Running in background" row. A subagent that ended
// remains a bounded status card in the tray and leaves one line where it ended
// (SubagentDoneLine.tsx), a failure in the danger color, a stopped one with why when known, and
// Restart on hover for one that did not finish. The tray's lines are the summary card's
// Subagents rows (AgentLine.tsx). The group card and the agents pill this replaces are
// subagents.gallery.ts, under Debug Settings agentPane.debug.subagentTray off.
import { agentPaneEntry } from "../../../gallery/format";
import {
  activity,
  assistant,
  chat,
  row,
  session,
  SESSION_ID,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, SubagentFold, type Subagent } from "./subagentFold";

const prompt = "Find out how the daemon updates itself, and check the docs agree";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.3, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

/** A Bash call Claude runs in the background, still running. */
const devServer = activity(
  [
    tool("bun run dev", "execute", "completed", {
      inputSummary: JSON.stringify({ command: "bun run dev", run_in_background: true }),
      startedAt: minutesAgo(1.5),
    }),
  ],
  1.5,
);

/** A long shell line Claude runs in the background, still running (Leo 2026-10-21: "is that a
 * command or a subagent?"). */
const testRun = activity(
  [
    tool("cd ~/fun/cmux-wt/chromium-transparency && RED=cb8f4178; GREEN=1 bun test", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/fun/cmux-wt/chromium-transparency && RED=cb8f4178; GREEN=1 bun test",
        description: "Run red/green tests",
        run_in_background: true,
      }),
      startedAt: minutesAgo(58.5),
    }),
  ],
  58.5,
);

/** A Bash call in the background that says what it does, behind a `cd` prefix. */
const described = activity(
  [
    tool("cd ~/Projects/cmux && cmux-ci compile-check --app", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/Projects/cmux && cmux-ci compile-check --app",
        description: "Compile the app on the fleet",
        run_in_background: true,
      }),
      startedAt: minutesAgo(1.4),
    }),
    tool("cd ~/Projects/cmux/webviews && CI=1 bun test test/subagent-tray.test.tsx", "execute", "completed", {
      inputSummary: JSON.stringify({
        command: "cd ~/Projects/cmux/webviews && CI=1 bun test test/subagent-tray.test.tsx",
        run_in_background: true,
      }),
      startedAt: minutesAgo(1.3),
    }),
  ],
  1.4,
);

/** A chat this chat's agent started (`acpmux new`), its turn running or ended. */
const child = (id: string, title: string, minutes: number, running: boolean, doing?: string) =>
  session({
    sessionId: id,
    title,
    spawnedBy: SESSION_ID,
    indicator: running ? "working" : "done",
    status: running ? "running" : "idle",
    createdAt: minutesAgo(minutes),
    ...(running && { lane: "working" as const }),
    ...(doing && { doing }),
  });

/** The subagents a Codex chat's records fold into, as acpmux wrote them for Leo's chat (2026-10-22):
 *  the child needs_you_review reported the chat's own thread as running under its own session, and
 *  every later record of the chat came tagged with the chat's id. The fold reads them by lineage. */
function codexLineage(): Subagent[] {
  const chatId = "01a1658b-c32f-72b1-ab04-d5444235a91c";
  const review = "01a16655-c696-7982-9c38-9ededd986f9b";
  const priorArt = "01a16656-bb2d-7513-b459-4a893451d37a";
  const fold = new SubagentFold();
  // The chat's own thread, as its summary names it.
  fold.chat = chatId;
  let seq = 0;
  const feed = (minutes: number, sessionId: string, update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    const msg = { method: "session/update", params: { sessionId, update, _meta: { acpmux } } };
    fold.reduce({ seq, at: minutesAgo(minutes), msg }, update);
  };
  const say = { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Starting the reviews." } };
  feed(22.5, chatId, say, {});
  feed(
    22.2,
    chatId,
    { sessionUpdate: "subagent_spawned", subagentSessionId: review },
    {
      subagents: [{ id: review, parent: null, name: "needs_you_review", task: "needs_you_review", state: "running" }],
    },
  );
  feed(
    21.97,
    review,
    { sessionUpdate: "subagent_state_update", subagentSessionId: chatId, state: "running" },
    {
      subagent: review,
      subagents: [{ id: chatId, parent: review, state: "running" }],
    },
  );
  feed(
    21.2,
    chatId,
    { sessionUpdate: "subagent_spawned", subagentSessionId: priorArt },
    {
      subagent: chatId,
      subagents: [{ id: priorArt, parent: chatId, name: "needs_you_prior_art", task: "needs_you_prior_art" }],
    },
  );
  return fold.all().map((agent) => ({ ...agent, action: agent.parent === null ? "git show --stat" : "Edit 2 files" }));
}

/** Waits for the tray's live `count` lines, and checks no group card is left in the transcript. */
const trayLines = (count: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(".acpmux-running-tray li:not([data-finished]) .acpmux-agent-line").length === count,
  );
  if (ctx.document.querySelector(".cv-subagents"))
    throw new Error("a running subagent must not draw a transcript card");
  if (ctx.document.querySelector(".acpmux-agents-pill"))
    throw new Error("the tray is the agents chip; no pill beside it");
};

/** A finished turn folds its work, each subagent's line with it (turns.ts `foldSegments`): open the
 * turn's Worked for, then wait for what the state shows. */
const openFold = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-worked"));
  await ctx.click({ selector: ".cv-worked" });
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray",
  title: "Running subagents tray",
  area: "Agent pane",
  height: 520,
  // The header and the composer stay put while the tray opens or folds.
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/subagents/restart.ts",
  ],
  variants: {
    "one-running": {
      note: "One subagent running: its line alone above the composer, its icon in the theme's accent, what it does now, its time and state.",
      play: trayLines(1),
      snapshot: chat(
        [
          user(prompt, 2),
          group([agent("Explain daemon update mechanism", 1.8, "running", { kind: "Explore", action: "Bash" })], 1.8),
          assistant("A subagent is reading the update code now; I'll report back when it is done.", 1.7),
        ],
        { isWorking: true },
      ),
    },
    "one-command": {
      note: "One background command: its line says Command before it, ends in a chevron (a click opens its output) and has no fill at rest; hover fills the whole line to the tray's edges, one inset. The whole shell line is its tooltip.",
      play: async (ctx) => {
        await trayLines(1)(ctx);
        if (ctx.document.querySelector(".acpmux-agent-line__kind")?.textContent !== "Command")
          throw new Error("a command's line says Command first");
      },
      snapshot: chat([user("Run the red/green tests in the background", 59), testRun], { isWorking: true }),
    },
    "after-latest-message": {
      note: "Labs/fixture placement: the running command tray sits directly after the latest message while the default remains above the composer. Expanding a command keeps its live tail bounded to the open row.",
      theme: { subagentTrayPlacement: "after-latest-message" },
      play: async (ctx) => {
        await trayLines(1)(ctx);
        if (!ctx.document.querySelector(".acpmux-transcript-after-latest .acpmux-running-tray"))
          throw new Error("after-latest placement must stay in the transcript flow");
        await ctx.click({ selector: ".acpmux-running-tray .acpmux-agent-line__button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__tail"));
      },
      snapshot: chat([user("Run the red/green tests in the background", 59), testRun], { isWorking: true }),
    },
    "several-running": {
      note: "Two subagents and a background command: a header with the counts and the time since the first started, a line each (up to three show open). The ended task remains a compact status card.",
      play: trayLines(3),
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            [
              agent("Read the updater", 1.9, "running", { kind: "Explore", action: "Read Sources/Updater.swift" }),
              agent("Check the docs", 1.9, "running", { kind: "general-purpose", action: "Read docs/updates.md" }),
              agent("Find the release script", 1.9, "completed", { kind: "Explore", ran: 0.6 }),
            ],
            1.9,
          ),
          devServer,
          assistant("Two subagents are on it, and the dev server is up.", 1.2),
        ],
        { isWorking: true },
      ),
    },
    "command-and-subagent": {
      note: "A turn with a subagent and a background command: a header with both counts, then a line each; the working line counts nothing, the tray is the count.",
      play: async (ctx) => {
        await trayLines(2)(ctx);
        if (ctx.document.querySelector(".cv-worked__open")) throw new Error("the tray is the count, not the line");
      },
      snapshot: chat(
        [
          user("Start the dev server, then have a subagent check the routes", 2),
          devServer,
          group([agent("Check the routes", 1.2, "running", { kind: "Explore", action: "Read src/routes.ts" })], 1.2),
        ],
        { isWorking: true },
      ),
    },
    "between-turns": {
      note: "After the turn: a background subagent and two chats the agent started still run. The tray says so above the composer; the transcript ends with the turn's footer.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
        if (ctx.document.querySelector(".cv-bgwork")) throw new Error("no Running in background row in the transcript");
      },
      snapshot: (() => {
        const base = chat([
          user("Split the migration into two chats and keep an eye on the logs", 7),
          group([agent("Watch the logs", 6.5, "running", { kind: "general-purpose", background: true })], 6.5),
          assistant("Two chats are migrating the settings store and the history page; a subagent watches the logs.", 5),
          summary(5, { status: "completed", durationMs: 70_000, toolCount: 1 }),
        ]);
        return {
          ...base,
          sessions: [
            ...base.sessions,
            session({
              sessionId: "child-1",
              title: "Migrate the settings store to SQLite",
              spawnedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.5),
            }),
            session({
              sessionId: "child-2",
              title: "Port the history page to React Aria",
              spawnedBy: SESSION_ID,
              indicator: "working",
              status: "running",
              createdAt: minutesAgo(5.4),
            }),
          ],
        };
      })(),
    },
    "counts-equal-rows": {
      note: "What Leo called lying, told straight: the header counts only what runs (2 subagents, 2 chats it started, all subagents; 2 commands) and equals the rows under it. A command reads as what it does, not its cd prefix; a chat says what its turn does now. What ended stays visible as bounded status cards.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        await ctx.click({ selector: ".acpmux-running-tray__head" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 3);
        const title = ctx.find({ selector: ".acpmux-running-tray__title" }).textContent;
        if (title !== "4 subagents running · 2 commands") throw new Error(`the header must count the rows: ${title}`);
      },
      snapshot: (() => {
        const base = chat(
          [
            user("Land the tray fix: two reviewers, the fleet compile and the tests", 3),
            group(
              [
                agent("Review the tray counts", 2.8, "running", {
                  kind: "general-purpose",
                  action: "Read runningTray.ts",
                }),
                agent("Review the fold", 2.8, "running", { kind: "general-purpose", action: "Grep subagent_progress" }),
                agent("Find the screenshot", 2.8, "completed", { kind: "Explore", ran: 0.4 }),
              ],
              2.8,
            ),
            described,
            assistant("Two reviewers are on it, the compile and the tests run, and two chats port the rest.", 1.2),
          ],
          { isWorking: true },
        );
        return {
          ...base,
          sessions: [
            ...base.sessions,
            child("child-1", "Port the history page to React Aria", 2.5, true, "Run bun test"),
            child("child-2", "Migrate the settings store to SQLite", 2.4, true, "Edit store.ts"),
            child("child-3", "Fix the dock hover", 9, false),
            child("child-4", "Draft the release notes", 8, false),
          ],
        };
      })(),
    },
    "codex-lineage": {
      note: 'A Codex chat\'s subagents as its records say (Leo 2026-10-22: "why is it like... staggered? were they created by another subagent?"): the chat itself started both, so they sit side by side. A child that reports its parent thread never makes the chat a subagent of its own, nested under that child.',
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
        const names = [...ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-summary-agent__name")];
        if (names.some((name) => /^[0-9a-f]{8}-/.test(name.textContent ?? "")))
          throw new Error("the chat is not one of its own subagents");
      },
      snapshot: chat(
        [
          user("Review the Needs you work and find prior art", 22.6),
          group(codexLineage(), 22.2),
          assistant("Two reviewers are on it.", 21),
        ],
        { isWorking: true, harness: "codex" },
      ),
    },
    "many-folded": {
      note: "Five running: the tray starts folded to its header so it never takes the transcript's room; the chevron opens the list.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        if (ctx.find({ selector: ".acpmux-running-tray__head" }).getAttribute("aria-expanded") !== "false")
          throw new Error("more than three running lines start folded");
      },
      snapshot: chat(
        [
          user("Review each package for unused exports", 2),
          group(
            ["net", "ui", "store", "router", "i18n"].map((name, index) =>
              agent(`Package ${name}`, 1.9 - index * 0.1, "running", { action: `Read src/${name}/index.ts` }),
            ),
            1.9,
          ),
        ],
        { isWorking: true },
      ),
    },
    "finished-line": {
      note: "A finished turn, its Worked for opened: each subagent left one quiet line where it ended, with its name and how long it ran; no tray.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent-done").length === 2);
        if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("nothing runs: no tray");
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Explain daemon update mechanism", 11.8, "completed", { ran: 1.3 }),
            agent("Check the docs", 11.8, "completed", { ran: 2.1 }),
          ],
          11.8,
        ),
        assistant("The daemon updates itself on launch; the docs agree except for the channel name.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    "failed-line": {
      note: "A subagent that failed says so in the danger color. A stopped one says why when the pane knows: the person stopped it (Stop), or a Send now interrupted its turn; one stopped for a reason the pane cannot know (another client's cancel, Claude's own TaskStop) says none rather than guess. One that did not finish offers Restart on hover.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('.cv-subagent-done[data-state="failed"]'));
        const texts = [...ctx.document.querySelectorAll(".cv-subagent-done")].map((line) => line.textContent ?? "");
        if (!texts.some((text) => text.includes("stopped by you")))
          throw new Error("a subagent the person stopped says so");
        if (!texts.some((text) => text.includes("interrupted by Send now")))
          throw new Error("a subagent a Send now stopped says so");
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Run the update tests", 11.8, "failed", { ran: 0.8, prompt: "Run the updater's tests" }),
            agent("Check the docs", 11.8, "cancelled", {
              ran: 1.6,
              stopReason: "user",
              prompt: "Check docs/updates.md",
            }),
            agent("Read the release script", 11.8, "cancelled", {
              ran: 1.9,
              stopReason: "sendNow",
              kind: "Explore",
              prompt: "Read scripts/release.sh",
            }),
            agent("Find the channel name", 11.8, "cancelled", { ran: 2.2 }),
          ],
          11.8,
        ),
        assistant("The update tests failed to start; the other checks were stopped.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    "restart-on-hover": {
      note: "Restart on a stopped subagent's line, shown on hover or keyboard focus (focused here): the hover row's compact button, its name and what it does on hover. It asks the chat to run the subagent again with its prompt.",
      play: async (ctx) => {
        await openFold(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-restart"));
        (ctx.document.querySelector(".cv-subagent-restart") as HTMLButtonElement).focus();
      },
      snapshot: chat([
        user(prompt, 12),
        group(
          [
            agent("Check the docs", 11.8, "cancelled", {
              ran: 1.6,
              stopReason: "user",
              kind: "Explore",
              prompt: "Check docs/updates.md",
            }),
          ],
          11.8,
        ),
        assistant("Stopped the docs check.", 9),
        summary(9, { status: "cancelled", durationMs: 110_000 }),
      ]),
    },
  },
});
