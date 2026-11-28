// A Cloud chat whose machine is paused rests (cmux#57136). cmux Cloud pauses an idle machine, and
// its chat's link to the machine's acpmux ends with it. The pane used to treat that as a lost link
// and ask again and again, saying "Reconnecting…" (quick asks for two minutes, then a failure line,
// then again on every focus of the window), though no ask can reach a paused machine and none may
// wake it. Now the pane keeps the chat it shows (the rows it had, or the kept tail), says nothing,
// and asks again only once the machine wakes: a send or a keystroke resumes it (cloudWake.ts), as
// does a terminal or a file opened on it (the app's attach), and the app then reads it live again.
import type { CloudChatState } from "./cloudChatRecovery";
import type { MachineLink } from "./machineLink";

export type CloudSleepFacts = {
  /// The app's link word for this pane's machine (machineLink.ts, pushed as it changes): `paused`
  /// for a Cloud machine the app reads as paused. Null for a chat on this Mac or an older app.
  link: MachineLink | null;
  /// The Cloud recovery's last read of the chat's machine (useCloudChatRecovery), while it reads.
  recovery: CloudChatState | undefined;
};

/// Whether the chat's Cloud machine sleeps, as the pane knows it now: only the app's own link word
/// says, since it follows the machine record live, so a machine woken elsewhere stops reading asleep
/// at once and the pane never rests on a running machine. The recovery's read (`recovery`) is one
/// read, not followed, so it never makes the pane rest: without a link word the pane recovers as before.
export function cloudChatAsleep(facts: CloudSleepFacts): boolean {
  return facts.link?.link === "paused";
}

/// The Cloud machine a send or a keystroke wakes while the chat rests, when the pane has no Cloud
/// identity from a handshake yet (a chat opened while its machine was already paused): the app's
/// link names the machine it reads as paused. Undefined otherwise.
export function cloudSleepingMachine(link: MachineLink | null): string | undefined {
  return link?.link === "paused" && link.machine ? link.machine : undefined;
}

/// Whether the pane, resting on a sleeping machine, asks again now: the machine stopped reading
/// asleep (a send's or a terminal's resume, a resume elsewhere) and no client is connected.
export function cloudWakeAsksAgain(state: { wasAsleep: boolean; asleep: boolean; connected: boolean }): boolean {
  return state.wasAsleep && !state.asleep && !state.connected;
}
