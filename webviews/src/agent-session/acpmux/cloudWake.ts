// A send in a Cloud chat whose machine is paused, or whose link is down (the machine paused itself
// while the chat was open), wakes the machine instead of failing. The prompt leaves the composer and
// waits in the pane's hold (trustHeld.ts `hold(..., waking)`) under "Waking the machine…"; the
// native attach resumes or reconnects the machine (`cloudMachine.attach`, the paused card's Resume
// path, useCloudChatRecovery.ts `resume`), the pane connects again, and the hold sends each prompt
// once, in order, when the chat is back. A wake that fails or runs out (useCloudChatRecovery's one
// minute) gives the prompts back to the composer.

export type CloudWakeState = {
  /// The chat runs on a Cloud machine of the account signed in (the handshake's identity).
  cloud: boolean;
  /// The chat shown, or the one the tab records while it is not listed (`missingSession`).
  chat: string | undefined;
  /// The pane can send to the chat's acpmux now: its link is up and its client took `chat.send`.
  linkUp: boolean;
  /// The machine reads paused (cloudChatRecovery.ts `cloudChatState`).
  paused: boolean;
  /// The tab's chat is not listed (the unavailable card shows).
  unavailable: boolean;
};

/// The chat a send now wakes its machine for, and waits in; undefined when it sends as usual.
export function cloudSendWakes(state: CloudWakeState): string | undefined {
  if (!state.cloud || !state.chat) return undefined;
  return !state.linkUp || state.paused || state.unavailable ? state.chat : undefined;
}

/// Leo, 2026-11-04: "as the user's selected cloud/is typing in it… that's when we can do an
/// optimistic resume". The person's keystroke in a Cloud chat whose machine the account reads as
/// paused wakes it then, so it is up (or on its way) by the time they send. Only a machine read as
/// asleep: a link that is only connecting (a chat just opened) is left alone. `woke` is the chat
/// this stretch of sleep already woke, so a wake runs once per stretch, not once per key; a send
/// then joins the wake in flight (useCloudChatRecovery `resume` runs one at a time).
export function cloudTypingWakes(
  state: CloudWakeState & { asleep: boolean; woke: string | undefined },
): string | undefined {
  if (!state.asleep) return undefined;
  const chat = cloudSendWakes(state);
  return chat !== state.woke ? chat : undefined;
}
