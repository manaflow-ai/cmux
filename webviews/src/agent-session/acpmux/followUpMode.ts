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

/// The steer flag each gesture sends with: Return and Send, or ⌘Return (the other choice).
export function followUpSteers(gesture: "return" | "commandReturn", mode: FollowUpMode, facts: FollowUpFacts): boolean {
  const queues = returnQueues(mode, facts);
  if (gesture === "commandReturn") return facts.steersAlways || queues;
  return !queues && (facts.steersAlways || facts.returnSteers || facts.steersUnseen);
}
