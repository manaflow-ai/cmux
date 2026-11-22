/// A prompt acpmux held for the folder trust answer keeps the gesture of the send that the user
/// made (the Enter), so the Trust click's own gesture goes to the trust answer and the prompt still
/// goes after it, once. At the refusal the pane reserves a gesture ticket bound to one promptId
/// (`transport.gesture {intent: {method: "session/prompt", params: {promptId}}}`); the next send
/// takes it and carries the ticket beside that promptId (`_meta.cmuxGesture`).
export type HeldPrompt = { promptId: string; ticket?: string };

export function heldPrompts(reserve: (intent: Record<string, unknown>) => Promise<string | undefined>) {
  let held: HeldPrompt | undefined;
  return {
    /// Keeps the current send's gesture for the prompt's next send (now, before any other click).
    hold(promptId: string = crypto.randomUUID()): Promise<void> {
      const mine: HeldPrompt = { promptId };
      held = mine;
      return reserve({ method: "session/prompt", params: { promptId } }).then(
        (ticket) => {
          if (held === mine && ticket) held = { promptId, ticket };
        },
        () => undefined,
      );
    },
    /// The held prompt's id and ticket, once; undefined when nothing is held.
    take(): HeldPrompt | undefined {
      const taken = held;
      held = undefined;
      return taken;
    },
  };
}
