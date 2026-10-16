// l10n-allow-file: gallery fixtures (sample chats and model names), not shipped UI.
// The composer's controls row (Composer.tsx, ComposerPickers.tsx, composerLocation.css)
// at the widths a chat pane takes (hq#1957 item 15): a left cluster (+, model, effort, the
// permission mode, 8 px apart) and a right cluster (mic, Send or Stop), with the row's free space only
// between the two; chips keep their full labels while the row has room, and a narrow pane drops
// the permission label first, then shortens effort, and the model last. These chats have started, so
// no location strip heads the card (locationRow.ts). test/composer-row-layout.test.ts measures it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, CATALOG, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
    { value: "xhigh", name: "Extra High" },
  ],
};

const modes = {
  currentModeId: "auto",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "edit", name: "Auto-accept edits", description: "Apply file edits without asking" },
    { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
    { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
  ],
};

// The chat in Leo's report: Claude Opus 5.5, Medium, Auto (no context ring: the model's tooltip says the usage).
function row(fields: Parameters<typeof chat>[1] = {}, extra: Partial<NonNullable<AcpmuxSnapshot["summary"]>> = {}) {
  const snapshot = chat(finished, { title: "Composer row", ...fields });
  return {
    ...snapshot,
    summary: { ...snapshot.summary!, configOptions: [effort], modes, ...extra },
  } satisfies AcpmuxSnapshot;
}

/// Fast mode as Claude Code offers it (off/on), or a speed option with a tier past Fast.
function speed(current: string, values = ["off", "on"]) {
  return {
    id: "fast-mode",
    name: "Fast mode",
    category: "model_config",
    currentValue: current,
    options: values.map((value) => ({ value })),
  };
}
const ULTRA = ["standard", "fast", "ultrafast"];

/** Exercise the real pane's native command boundary, then return to the still's starting tier. */
function cycleSpeed(current: string, values = ["off", "on"]): Play {
  return async (ctx) => {
    type Message = { method?: string; params?: { configId?: string; value?: string } };
    const pane = ctx.document.defaultView as unknown as {
      webkit: { messageHandlers: { agentSession: { postMessage(message: Message): unknown } } };
      cmuxAcpmuxBridge: { receive(snapshot: AcpmuxSnapshot): void };
    };
    const handler = pane.webkit.messageHandlers.agentSession;
    const original = handler.postMessage;
    const picks: string[] = [];
    handler.postMessage = (message) => {
      if (message.method === "chat.effort" && message.params?.configId === "fast-mode" && message.params.value)
        picks.push(message.params.value);
      return original(message);
    };
    const target = { selector: ".acpmux-composer-actions .acpmux-fast" } as const;
    try {
      await ctx.waitFor(() => ctx.document.querySelector(target.selector));
      if (ctx.document.defaultView!.innerWidth < 370) {
        if (ctx.document.defaultView!.getComputedStyle(ctx.find(target)).display !== "none")
          throw new Error("the speed button must give way in the narrowest pane");
        return;
      }
      const actions = ctx.find(target).parentElement!;
      const buttons = [...actions.querySelectorAll("button")];
      const at = buttons.indexOf(ctx.find(target) as HTMLButtonElement);
      if (!buttons[at + 1]?.classList.contains("acpmux-mic")) throw new Error("speed must be before dictation");
      const start = values.indexOf(current);
      for (let step = 1; step <= values.length; step += 1) {
        const next = values[(start + step) % values.length]!;
        picks.length = 0;
        await ctx.click(target);
        await ctx.waitFor(() => picks.length > 0);
        if (picks[0] !== next) throw new Error(`speed command: expected ${next}, received ${picks[0]}`);
        // As the app does, publish the session's confirmed option through the pane bridge.
        pane.cmuxAcpmuxBridge.receive(row({}, { configOptions: [effort, speed(next, values)] }));
        const tier = next === values[0] ? "off" : next === values[1] ? "fast" : "ultrafast";
        await ctx.waitFor(() => ctx.find(target).getAttribute("data-tier") === tier);
        if (ctx.find(target).getAttribute("aria-pressed") !== String(tier !== "off"))
          throw new Error("speed pressed state must follow the confirmed tier");
      }
    } finally {
      handler.postMessage = original;
    }
  };
}

const LONG_MODEL = "claude-opus-5-5-1m";
const longCatalog = CATALOG.map((entry) =>
  entry.id === "claude"
    ? {
        ...entry,
        models: [
          {
            id: LONG_MODEL,
            name: "Opus 5.5 with a one-million-token context window",
            efforts: ["low", "medium", "high", "max"],
          },
          ...entry.models,
        ],
      }
    : entry,
);

export default agentPaneEntry({
  id: "agent-pane.composer-row",
  title: "Composer controls row",
  area: "Agent pane",
  height: 300,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-bar" }, { selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/FastToggle.tsx#FastToggle",
    "agent-session/acpmux/FastToggle.tsx#SpeedToggleHost",
  ],
  variants: {
    "claude-auto": {
      note: "Claude Opus 5.5, Medium and Auto in one evenly spaced left cluster; mic and Send on the right.",
      snapshot: row(),
    },
    "long-model": {
      note: "A long model name: it shows whole while the row has room and is the last label to shorten.",
      snapshot: { ...row({ model: LONG_MODEL }), catalog: longCatalog },
    },
    granted: {
      note: "A chat-wide allowance: the row still shows one lock, the mode's; the granted status gets no slot in it.",
      snapshot: {
        ...row(),
        permissionGroups: {
          supported: true,
          ready: true,
          busy: false,
          loading: false,
          chatAllowance: true,
          groups: [],
        },
      },
    },
    "speed-off": {
      note: "A model with fast mode, off: the muted bolt sits left of the mic; the effort chip reads Medium.",
      snapshot: row({}, { configOptions: [effort, speed("off")] }),
      play: cycleSpeed("off"),
    },
    "speed-fast": {
      note: "Fast on: the bolt takes the accent ink and the effort chip still reads Medium, with no Fast word.",
      snapshot: row({}, { configOptions: [effort, speed("on")] }),
      play: cycleSpeed("on"),
    },
    "speed-ultrafast": {
      note: "An option with a tier past Fast, on Ultrafast: the bolt is filled in the accent ink.",
      snapshot: row({}, { configOptions: [effort, speed("ultrafast", ULTRA)] }),
      play: cycleSpeed("ultrafast", ULTRA),
    },
    queued: {
      note: "A running turn with prompts queued above the field: Stop takes Send's circle, the row keeps its clusters.",
      snapshot: {
        ...row({ isWorking: true }),
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      },
    },
  },
});
