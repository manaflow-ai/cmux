// When the composer binds the Enter or click of a send it holds for its files (a pasted file still
// read or uploaded) to that prompt at once (Composer `onBindSendGesture`, Leo 2026-11-06: "why is
// this still happening"). The host keeps one grant per key press or click: whatever spends it
// between the Enter and the send leaves the other refused. A send into the chat open now spends
// it only on its own prompt (an upload has a credit of its own), so it binds at once. Anything
// that starts or wakes a chat first needs that grant itself, so the send binds nothing early and
// gets its ticket as it goes, as before: a new chat's start (New Tab, a picked project), a harness
// switch (deferred behind a running turn, starting, or waiting for Trust; its remote session/new),
// a Cloud start or wake, a sandbox run.

/// Where a send held for its files goes, read at its Enter or click.
export type HeldSendRoute = {
  /// The chat the client has selected; undefined before a new chat's start.
  openChat: string | undefined;
  /// A harness switch holds sends (any phase, deferred included).
  switchPending: boolean;
  /// The send starts a new chat (a picked project with no chat yet).
  startsChat: boolean;
  /// The send starts a Cloud chat (`cloud.startChat`).
  cloudStart: boolean;
  /// The send wakes the chat's Cloud machine first (cloudWake.ts).
  cloudWake: boolean;
  /// The send runs on a sandbox, or is refused there.
  sandbox: boolean;
};

/// Whether the held send binds its gesture now: only when it goes straight to the chat open now.
export function bindsHeldSendNow(route: HeldSendRoute): boolean {
  return (
    route.openChat !== undefined &&
    !route.switchPending &&
    !route.startsChat &&
    !route.cloudStart &&
    !route.cloudWake &&
    !route.sandbox
  );
}
