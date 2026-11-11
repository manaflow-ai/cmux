// What the transcript says of a sender acpmux could not verify, from what the daemon itself found
// behind the send rather than what the sender claimed (acpmux sender_program.rs). Leo, 2026-11-11,
// on our own outbox relay's notice drawn as "Unverified sender" with an "Xcode" chip: "surely this
// could be more... idk. generally the "unverified sender" things should be more verified".
//
// The daemon walks the unix socket peer's process chain and records, on the prompt's provenance:
// - `verified: true, verifiedBy: "program", program` when a named sender's program is the one the
//   host's owner-only registry (`~/.acpmux/senders.json`) lists for that name: a first-party sender,
//   drawn by its name with no unverified mark;
// - `identified: {program?, app?}` on any other unverified one: what it found (a script's name such
//   as `outbox_relay.py`, an executable's, an app only when the process is that app's own code).
// A claim (a name the sender gave, its harness) is still only a claim: the mark's words say so, and
// name what was identified instead.
import type { Translate } from "../i18n";

/// What the daemon identified behind an unverified send.
export type IdentifiedSender = { program?: string; app?: string };

/// Longest identified name kept, in characters.
const MAX = 128;

function word(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.trim();
  return text && text.length <= MAX && !/\p{Cc}/u.test(text) ? text : undefined;
}

/// The provenance's `identified`, its fields one line each; undefined with none.
export function identifiedOf(provenance: Record<string, unknown> | undefined): IdentifiedSender | undefined {
  const raw = provenance?.identified;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const { program, app } = raw as Record<string, unknown>;
  const found = { ...(word(program) && { program: word(program) }), ...(word(app) && { app: word(app) }) };
  return found.program || found.app ? found : undefined;
}

/// Whether acpmux verified a named sender by its program (the host's registry): its name stands.
export function verifiedByProgram(provenance: Record<string, unknown> | undefined): boolean {
  return provenance?.verified === true && provenance.verifiedBy === "program";
}

/// The name the daemon's find reads as: the program (`outbox_relay.py`), else the app (`Xcode`).
export function identifiedName(identified: IdentifiedSender | undefined): string | undefined {
  return identified?.program ?? identified?.app?.replace(/\.app$/, "");
}

/// The sender's name on a line that names none: what was identified, "via acpmux CLI", else
/// "Unverified sender".
export function unnamedSender(t: Translate, identified: IdentifiedSender | undefined): string {
  const name = identifiedName(identified);
  return name ? t("message.identifiedSender", { name }) : t("message.unverifiedSender");
}

/// What the unverified mark says why of: the name the sender claimed, what acpmux identified, the
/// machine its CLI named.
export type UnverifiedWhy = { claimed?: string; identified?: IdentifiedSender; host?: string };

/// A received message's [`UnverifiedWhy`]: its name is only its claim.
export const whyOf = (message: { name: string; identified?: IdentifiedSender; host?: string }): UnverifiedWhy => ({
  ...(message.name.trim() && { claimed: message.name.trim() }),
  ...(message.identified && { identified: message.identified }),
  ...(message.host && { host: message.host }),
});

/// Why the sender is marked unverified, for the mark's tooltip and accessible name: what it claimed
/// ("Claimed to be glaeda-gh, not proven"), then what the daemon identified ("Sent by
/// outbox_relay.py via acpmux CLI on cosmic-gray"); "Sender not verified" with neither.
export function unverifiedWhy(t: Translate, why: UnverifiedWhy): string {
  const name = identifiedName(why.identified);
  const lines = [
    why.claimed?.trim() ? t("message.claimedNotProven", { name: why.claimed.trim() }) : undefined,
    name
      ? why.host
        ? t("message.sentByOnHost", { name, host: why.host })
        : t("message.sentBy", { name })
      : undefined,
  ].filter((line): line is string => !!line);
  return lines.length ? lines.join("\n") : t("message.senderUnverified");
}
