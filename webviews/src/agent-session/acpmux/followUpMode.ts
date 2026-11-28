// `agentPane.followUpMode` (Settings > Agent Chat > Follow-Up Messages): what Return and Send do with
// a message sent while an agent that steers is mid-turn. "steer" (the default, as always) takes it
// into the running turn and ⌘Return queues it for after the turn; "queue" holds it until the turn
// ends and ⌘Return steers it in, so the other key always does the other thing.
//
// An agent that cannot steer queues on every key either way, and queueing off (queueing.ts) steers
// on every key either way. The composer only picks the steer flag of the send; acpmux then steers a
// prompt marked steer into the running turn and queues any other behind it.
export type FollowUpMode = "steer" | "queue";

/// The host's value; anything else is the default, "steer".
export function readFollowUpMode(value: unknown): FollowUpMode {
  return value === "queue" ? "queue" : "steer";
}

export type FollowUpFacts = {
  /// Return would steer today: a turn runs, the agent steers, and there is something to send.
  returnSteers: boolean;
  /// Queueing is off, so every key steers.
  steersAlways: boolean;
  /// No turn shows yet, but the agent steers: a steer starts a turn when none runs.
  steersUnseen: boolean;
};

/// Whether Return (and Send, which does what Return does) holds the message for after the turn.
export function returnQueues(mode: FollowUpMode, facts: FollowUpFacts): boolean {
  return mode === "queue" && facts.returnSteers && !facts.steersAlways;
}

/// Every way the composer sends a draft. Each one's steer flag is decided here, and only here:
/// - `return`: Return, and Send (the button does what Return does);
/// - `commandReturn`: ⌘Return, the other choice;
/// - `menuQueue`: Send's menu's Queue for later, offered only while Return steers (sendMenuModel.ts);
/// - `quickOpen`: the Quick Composer's ⌘Return, which sends and opens the chat's window.
export type SendKey = "return" | "commandReturn" | "menuQueue" | "quickOpen";

/// The steer flag each gesture sends with. acpmux steers a prompt marked steer into the running
/// turn (or starts one when none runs) and queues any other behind it.
export function followUpSteers(key: SendKey, mode: FollowUpMode, facts: FollowUpFacts): boolean {
  switch (key) {
    case "return": {
      const queues = returnQueues(mode, facts);
      return !queues && (facts.steersAlways || facts.returnSteers || facts.steersUnseen);
    }
    case "commandReturn":
      return facts.steersAlways || returnQueues(mode, facts);
    case "menuQueue":
      // Queue for later queues, unless queueing is off: then nothing new waits.
      return facts.steersAlways;
    case "quickOpen":
      // The window opens on the chat: what is sent steers only where Return could not hold it.
      return facts.steersAlways || facts.steersUnseen;
  }
}
