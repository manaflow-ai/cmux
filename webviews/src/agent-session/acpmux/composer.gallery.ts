// l10n-allow-file: gallery fixtures (sample drafts and chats), not shipped UI.
// The composer's states (Composer.tsx, ComposerPickers.tsx, ComposerContext.tsx: the prompt,
// the mode and model chips, the location row, Send and Stop), through the pane's own inputs: the
// `ready` answer's draft and new-chat fields, and the snapshot.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, CWD, noChat, session, summary, user } from "../../gallery/fixtures/acpmux";

const working = [user("Add retries", 1), assistant("Reading the helper…", 0.5, { streaming: true })];
// Three prompts waiting for the running turn.
const waiting = [
  { id: "q1", prompt: "Then add a test for the 429 path" },
  { id: "q2", prompt: "And update the README" },
  { id: "q3", prompt: "Run the whole suite" },
];

// A chat started without a project lives in cmux's agent home, one UUID folder per chat.
const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

const composerControls = {
  configOptions: [
    {
      id: "thought_level",
      name: "Speed",
      category: "thought_level",
      currentValue: "medium-fast",
      options: [
        { value: "slow", name: "Slow" },
        { value: "medium-fast", name: "Medium Fast" },
        { value: "fast", name: "Fast" },
      ],
    },
  ],
  modes: {
    currentModeId: "bypassPermissions",
    availableModes: [
      { id: "ask", name: "Ask before edits", description: "Review changes before they run" },
      { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
    ],
  },
};

export default agentPaneEntry({
  id: "agent-pane.composer",
  title: "Composer",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  // The transcript must not move while a play step opens a menu over it, and the composer box
  // must not move when queued prompts come and go above it.
  anchors: [
    { selector: ".acpmux-scroll" },
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-context" },
  ],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Footer menus and the capped draft must preserve the transcript and footer geometry.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The location row is the composer card's footer and must not reflow the transcript.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Composer interactions must stay below one display frame on the gallery host.",
    },
  },
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/composer/PromptEditor.tsx",
    "agent-session/acpmux/MarkdownField.tsx",
    "agent-session/acpmux/EffortPicker.tsx",
    "agent-session/acpmux/EmptyState.tsx",
    "agent-session/acpmux/ComposerQueue.tsx#ComposerQueue",
  ],
  variants: {
    "new-chat": {
      note: "A new chat: empty prompt; the card's footer row holds the folder and computer, under a hairline.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
    },
    "agent-home": {
      note: "A new chat with no project (cmux's agent home): the hero asks what to build, the folder reads Choose folder.",
      ready: { newSession: true, cwd: AGENT_HOME, chooseFolder: true },
      // A new chat's session starts at once (the prewarmed process), so the snapshot and its
      // summary name the same session, as the app's do; the folder control is then the new chat's
      // folder menu (Choose folder…), not the path field.
      snapshot: noChat([], {
        sessionId: "prewarmed",
        summary: {
          sessionId: "prewarmed",
          cwd: AGENT_HOME,
          harness: "claude",
          model: "claude-opus-5-5",
          effort: "high",
        },
      }),
    },
    "agent-home-path": {
      note: "Play: a chat the folder field serves (no folder list from the host): the field reads as a menu row, never a native text box.",
      ready: { cwd: AGENT_HOME, chooseFolder: true },
      snapshot: noChat([], {
        summary: { sessionId: "", cwd: AGENT_HOME, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-search"));
      },
    },
    "agent-home-folders": {
      note: "Play: open the folder menu; it lists real projects, never the agent home's UUID folders.",
      ready: { newSession: true, cwd: AGENT_HOME, chooseFolder: true },
      snapshot: noChat(
        [
          session({ sessionId: "home-chat", title: "A chat with no project", cwd: AGENT_HOME }),
          session({ sessionId: "atlas", title: "Retry the fetch helper" }),
          session({ sessionId: "cmux", title: "Fix the sidebar", cwd: "/Users/you/src/cmux" }),
        ],
        { summary: { sessionId: "", cwd: AGENT_HOME, harness: "claude", model: "claude-opus-5-5", effort: "high" } },
      ),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
      },
    },
    idle: {
      note: "After a turn: Send, the mode and model chips.",
      snapshot: chat(finished),
    },
    // POLISH.md right-click contract: the prompt's own menu over selected text, never WebKit's.
    "context-menu": {
      note: "Right-click on selected prompt text: Cut, Copy, Paste, Paste as Plain Text, Attach Files…, Insert Mention.",
      ready: { draft: "Add retries with backoff to the fetch helper" },
      snapshot: chat(finished),
      play: async (ctx) => {
        const field = ctx.find({ selector: ".acpmux-md" });
        ctx.document.defaultView!.getSelection()!.selectAllChildren(field);
        const box = field.getBoundingClientRect();
        field.dispatchEvent(
          new MouseEvent("contextmenu", {
            bubbles: true,
            cancelable: true,
            clientX: box.left + 40,
            clientY: box.top + 12,
          }),
        );
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
      },
    },
    // Leo (dogfood 2026-10-08, 22-composer-image-chip.png): a pasted image draws as a cropped
    // thumbnail above the prompt, with a small × that shows on hover; a click opens the viewer.
    "image-attached": {
      note: "A pasted screenshot: a cropped thumbnail above the prompt, its small × shown on hover.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const canvas = new view.OffscreenCanvas(320, 200);
        const paint = canvas.getContext("2d")!;
        const gradient = paint.createLinearGradient(0, 0, 320, 200);
        gradient.addColorStop(0, "#f2b134");
        gradient.addColorStop(1, "#3a7bd5");
        paint.fillStyle = gradient;
        paint.fillRect(0, 0, 320, 200);
        paint.fillStyle = "#ffffff";
        paint.fillRect(40, 60, 240, 16);
        paint.fillRect(40, 92, 180, 16);
        const file = new view.File([await canvas.convertToBlob({ type: "image/png" })], "screenshot.png", {
          type: "image/png",
        });
        const field = ctx.find({ selector: ".acpmux-md" });
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files: [file], types: ["Files"] } });
        field.dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img[src^='data:image/png']"));
        await ctx.hover({ selector: ".acpmux-attachment-image" });
      },
    },
    "pdf-attached": {
      note: "A pasted PDF shows a preview card, its file name, and the detected page count before sending.",
      snapshot: chat(finished),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const pdf = `%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n2 0 obj << /Type /Page >> endobj\n%%EOF`;
        const file = new view.File([pdf], "design-notes.pdf", { type: "application/pdf" });
        const field = ctx.find({ selector: ".acpmux-md" });
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files: [file], types: ["Files"] } });
        field.dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-document"));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-document[data-page-count='2']"));
        await ctx.click({ selector: ".acpmux-attachment-document-open" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pdf-viewer"));
      },
    },
    draft: {
      note: "A draft the tab inherited (markdown, two lines).",
      ready: { draft: "Also add a **circuit breaker** after `5` failures.\nKeep the POST rule as is." },
      snapshot: chat(finished),
    },
    "long-draft": {
      note: "A long draft: the field grows to its limit, then scrolls.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished),
    },
    "long-draft-light": {
      note: "The capped long draft in the light theme proof matrix.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished, { summary: { ...chat(finished).summary!, ...composerControls } }),
    },
    "long-draft-dark": {
      note: "The capped long draft in the dark theme proof matrix.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished, { summary: { ...chat(finished).summary!, ...composerControls } }),
    },
    working: {
      note: "A turn running: Send becomes Stop.",
      snapshot: chat(working, { isWorking: true }),
    },
    queued: {
      note: "Two prompts waiting for the running turn: numbered rows on the composer's top edge.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
    },
    "queued-long": {
      note: "Many queued prompts, one too long for its row: the rows scroll, and the cut-off one shows a tooltip on hover.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          {
            id: "q2",
            prompt:
              "Once the retries land, go through every caller of the fetch helper and make sure none of them retries on its own as well, then summarize what changed",
          },
          { id: "q3", prompt: "And update the README" },
          { id: "q4", prompt: "Run the whole suite" },
          { id: "q5", prompt: "Open a PR" },
        ],
      }),
      play: async (ctx) => {
        await ctx.hover({ text: /^Once the retries land/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-queued-text[title]"));
      },
    },
    "queued-send-remove": {
      note: "Play: remove the first waiting prompt from its row, then Stop: the turn ends and the next prompt is sent. Neither moves the composer, the transcript or the rows below.",
      snapshot: chat(working, { isWorking: true, queue: waiting }),
      native: { "chat.queue.remove": { removed: true } },
      then: {
        // acpmux ends the turn and starts the next queued prompt (q2): its rows join the transcript.
        "chat.cancel": chat(
          [
            working[0]!,
            { ...working[1]!, version: 2, streaming: false },
            user("And update the README", 0),
            assistant("Looking at the README…", 0, { streaming: true }),
          ],
          { isWorking: true, queue: waiting.slice(2) },
        ),
      },
      play: async (ctx) => {
        await ctx.hover({ text: "Then add a test for the 429 path" });
        await ctx.click({ selector: '.acpmux-queued:first-child button[aria-label="Remove queued prompt"]' });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 2);
        await ctx.click({ role: "button", name: "Stop" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 1);
      },
    },
    "codex-model": {
      note: "Another harness and model in the chips.",
      snapshot: chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex chat" }),
    },
    "tray-long-branch": {
      note: "The footer row keeps a long branch readable without moving the composer.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
    },
    "docked-400": {
      note: "The card's footer row at a 400px dock width.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
    },
    "wide-760": {
      note: "The composer card and its footer row at the 760px wide proof width.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
    },
    "folder-menu": {
      note: "Play: open the footer's folder menu; it draws above the whole card, opaque, rows legible.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-context .acpmux-location-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu, [role='dialog']"));
      },
    },
    "context-usage-menu": {
      note: "Play: right-click the context ring; Hide Context Usage hides it, and a right-click on the footer then offers Show Context Usage.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-usage",
          harness: "claude",
          model: "claude-opus-5-5",
          cwd: CWD,
          turnCount: 2,
          usage: { used: 48_000, size: 200_000 },
        },
      }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("button.acpmux-context-ring"));
        const ring = ctx.document.querySelector<HTMLElement>("button.acpmux-context-ring")!;
        const box = ring.getBoundingClientRect();
        const view = ctx.document.defaultView!;
        ring.dispatchEvent(
          new view.MouseEvent("contextmenu", {
            bubbles: true,
            cancelable: true,
            clientX: box.left + 4,
            clientY: box.top + 4,
          }),
        );
        await ctx.waitFor(() => ctx.document.querySelector(".ui-context-menu [role=menuitem]"));
      },
    },
    "add-menu": {
      note: "Play: open +; Attach files or images comes first and opens the file chooser, and the menu rises out of +.",
      snapshot: chat(finished, {
        commands: [{ name: "compact", description: "Clear conversation history but keep a summary in context" }],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-composer-plus [data-value="attach"]'));
      },
    },
    "context-breakdown": {
      note: "Play: open the context ring after a first message on Codex; the details split Agent setup (system prompt, tools and instructions) from the conversation.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-context",
          harness: "codex",
          model: "gpt-5.5",
          cwd: CWD,
          turnCount: 1,
          usage: { used: 25_300, size: 258_400 },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "button.acpmux-context-ring" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-part"));
      },
    },
    "slash-menu": {
      note: "Play: type / in the prompt; the agent's command menu opens.",
      snapshot: chat(finished, {
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
          { name: "review", description: "Review a pull request" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/");
        await ctx.waitFor(() => ctx.document.querySelector("[role='listbox'], [role='menu']"));
      },
    },
    "slash-fork": {
      note: "Play: type /fork; the cmux-owned fork command appears with the harness commands.",
      snapshot: chat([...finished.slice(0, -1), summary(9, { status: "completed", seq: 12 })], {
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "review", description: "Review a pull request" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/fork");
        await ctx.waitFor(() =>
          Array.from(ctx.document.querySelectorAll(".acpmux-slash-name")).some((node) => node.textContent === "/fork"),
        );
      },
    },
    "reasoning-claude": {
      note: "Play: Claude's reasoning menu: Low to Max with Extra High, Ultracode (with its line), Ultrathink, then Fast Mode On/Off; the chip reads Medium Fast.",
      snapshot: withSummary(chat(finished, { title: "Claude reasoning" }), {
        configOptions: [
          {
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: "medium",
            options: [
              { value: "default", name: "Default" },
              { value: "low", name: "Low" },
              { value: "medium", name: "Medium" },
              { value: "high", name: "High" },
              { value: "xhigh", name: "Extra High" },
              { value: "max", name: "Max" },
              { value: "ultracode", name: "Ultracode" },
              { value: "ultrathink", name: "Ultrathink" },
            ],
          },
          {
            id: "fast-mode",
            name: "Fast mode",
            category: "model_config",
            currentValue: "on",
            options: [
              { value: "off", name: "Off" },
              { value: "on", name: "On" },
            ],
          },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-effort .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-menu"));
      },
    },
    "reasoning-codex": {
      note: "Play: Codex's reasoning menu: Low to Ultra (Xhigh reads Extra High), then Service Tier Standard (Default) and Fast with Codex's own line.",
      snapshot: withSummary(chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex reasoning" }), {
        configOptions: [
          {
            id: "reasoning_effort",
            category: "thought_level",
            currentValue: "medium",
            options: ["low", "medium", "high", "xhigh", "max", "ultra"].map((value) => ({ value })),
          },
          {
            id: "fast-mode",
            category: "model_config",
            currentValue: "off",
            options: [
              { value: "off", name: "Off", description: "Default speed, normal usage" },
              { value: "on", name: "On", description: "1.5x speed, increased usage" },
            ],
          },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-effort .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-effort-menu"));
        await ctx.click({ role: "menuitemradio", name: /^Fast/ });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-effort-menu"));
      },
    },
    "model-menu-keyboard": {
      note: "Play: open the model picker and move its highlight with the keyboard.",
      snapshot: chat(finished, {
        harness: "claude",
        model: "claude-opus-5-5",
        title: "Model picker interaction",
      }),
      play: async (ctx) => {
        const picker = ".acpmux-model .acpmux-picker-button";
        await ctx.click({ selector: picker });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-model .acpmux-mp"));
        const search = ctx.find({ selector: ".acpmux-mp input[role=combobox]" });
        await ctx.waitFor(() => ctx.document.activeElement === search);
        const previous = search.getAttribute("aria-activedescendant");
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => {
          const current = search.getAttribute("aria-activedescendant");
          return current !== previous && Boolean(current && ctx.document.getElementById(current));
        });
      },
    },
    "picker-toggle": {
      note: "Play: open the permission picker, then press its trigger again; the menu closes and does not reopen on the same WebKit click.",
      snapshot: withSummary(chat(finished, { title: "Picker toggle" }), {
        sessionId: "gallery-picker-toggle",
        harness: "claude",
        model: "claude-opus-5-5",
        cwd: CWD,
        turnCount: 1,
        modes: composerControls.modes,
      }),
      play: async (ctx) => {
        const trigger = '[aria-label="Mode"]';
        await ctx.click({ selector: trigger });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
        await ctx.click({ selector: trigger });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
      },
    },
    "reasoning-menu": {
      note: "Play: open Reasoning; a small menu lists only the model's levels and checks the current one.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-reasoning",
          harness: "codex",
          model: "gpt-5.5",
          cwd: CWD,
          turnCount: 1,
          configOptions: [
            {
              id: "reasoning_effort",
              name: "Reasoning",
              category: "thought_level",
              currentValue: "high",
              options: [
                { value: "low", name: "Low" },
                { value: "medium", name: "Medium" },
                { value: "high", name: "High" },
                { value: "xhigh", name: "Extra high" },
              ],
            },
          ],
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[data-menu="Effort"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
      },
    },
    "reasoning-none": {
      note: "A model whose only level is the agent's default shows no reasoning control, never Default / Default.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-reasoning-none",
          harness: "claude",
          model: "claude-opus-5-5",
          cwd: CWD,
          turnCount: 1,
          configOptions: [
            {
              id: "effort",
              name: "Effort",
              category: "thought_level",
              currentValue: "default",
              options: [{ value: "default", name: "Default" }],
            },
          ],
        },
      }),
    },
    "model-menu-starred": {
      note: "Play: open the model picker, star Sonnet, then open the rail's Starred tab: it lists the starred models of every harness.",
      snapshot: chat(finished, { harness: "claude", model: "claude-opus-5-5", title: "Starred models" }),
      play: async (ctx) => {
        const { translate } = await import("./i18n");
        const starred = { role: "option", name: translate("picker.starred") };
        const favorite = { selector: '.acpmux-mp-favorite[aria-label$="Sonnet 5.5"]' };
        await ctx.click({ selector: ".acpmux-model .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-model .acpmux-mp"));
        // A full provider catalog places Sonnet below the visible rows. Filter it into view
        // before pointer input, then reveal the row's hover-only favorite control.
        await ctx.type("Sonnet 5.5", { selector: ".acpmux-mp input[role=combobox]" });
        await ctx.hover(favorite);
        // Replay retains the pane's favorites. Keep Sonnet starred instead of toggling it off.
        if (ctx.find(favorite).getAttribute("aria-pressed") !== "true") await ctx.click(favorite);
        // Tooltips consume title on hover; the translated accessible name stays available.
        await ctx.click(starred);
        await ctx.waitFor(
          () =>
            ctx.find(starred).getAttribute("aria-selected") === "true" &&
            [...ctx.document.querySelectorAll(".acpmux-mp-models .acpmux-menu-label")].some((row) =>
              row.textContent?.endsWith("Sonnet 5.5"),
            ),
        );
      },
    },
    "model-switching": {
      note: "A switch from Claude Code to Codex is starting: the chip draws the Codex mark with its name, never one harness's mark beside another's name.",
      snapshot: chat(finished, {
        harness: "claude",
        model: "claude-opus-5-5",
        title: "Switching harness",
        switching: { harness: "codex", name: "Codex", phase: "starting" },
      }),
    },
    "access-menu": {
      note: "The footer keeps permission mode behind a quiet lock; the menu explains each choice and checks the active one.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-access",
          harness: "claude",
          model: "claude-opus-5-5",
          effort: "high",
          cwd: CWD,
          host: "This Mac",
          hostKind: "local",
          branch: "main",
          turnCount: 1,
          usage: { used: 48_000, size: 200_000 },
          promptCapabilities: { image: true },
          modes: {
            currentModeId: "ask",
            availableModes: [
              { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
              { id: "edit", name: "Auto-accept edits", description: "Apply file edits without asking" },
              { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
              { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
            ],
          },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
      },
    },
    disconnected: {
      note: "The daemon connection dropped.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
  },
});

/// A chat snapshot with extra summary fields (the agent's config options).
function withSummary(
  snapshot: ReturnType<typeof chat>,
  summary: Partial<NonNullable<ReturnType<typeof chat>["summary"]>>,
): ReturnType<typeof chat> {
  return { ...snapshot, summary: { ...snapshot.summary!, ...summary } };
}
