// Who sent another agent's message, as acpmux's sender record says (prompt_provenance.rs
// `sender_record`: `verification`, `harness`, and for a broker-relayed message `relay`), and the
// name the transcript draws for it. An older acpmux wrote what it could not verify into the name
// itself (hub/inbox.rs `display_sender`: "gcp-agent-lane-2/lock-proof-routes (self-declared,
// unauthenticated)"), and the thread's label too ("#36125 (self-declared, unauthenticated)"). Leo,
// 2026-11-07: "Why does it say blah blah unauthenticated? ... Why does it say it's self-declared if
// we can just detect the thing?" The name reads bare; a sender the daemon could not verify gets a
// small marker by its name (UnverifiedMark.tsx), never words in the name. Every surface that names a
// sender (the received line, the inbox thread, the minimap's sender, the waiting group) reads it here.

/// The words an older acpmux appended to a name it could not verify.
const UNVERIFIED_SUFFIX = /\s*\(self-declared, unauthenticated\)\s*$/i;

/// How acpmux knows the sender: `verified` by its session, `declared` (it only named itself with
/// `--from`), `legacy` (a record from before it said).
export type SenderVerification = "verified" | "declared" | "legacy";

/// A broker-relayed message's relay (the new sender record's `relay`).
export type SenderRelay = { by?: string; machine?: string; session?: string };

export type SenderRecord = {
  verification?: SenderVerification;
  /// The sender's harness family (`claude`, `codex`, `gemini`, ...), for its mark.
  harness?: string;
  relay?: SenderRelay;
  /// The name the sender declared (`--from`), as acpmux kept it: never cut, so a reader that opens
  /// the sender's chat by its record (an agent chip) finds it.
  label?: string;
  /// The sender's session, when acpmux knows it.
  session?: string;
};

/// A relayed sender's address (`MACHINE/SESSION`, the relay's `--relayed-from`), whole: the chat its
/// chip asks for. acpmux's label for it is cut to `fromAgent`'s 64 characters (prompt_provenance.rs
/// `relayed_label`), so two sessions sharing their first 64 read as one there (cmux#38642 review).
export const relayAddress = (relay: SenderRelay | undefined): string | undefined =>
  relay?.machine && relay.session ? `${relay.machine}/${relay.session}` : undefined;

/// `name` without the unverified suffix an older acpmux wrote into it, and whether it had one.
export function bareSender(name: string): { name: string; declared: boolean } {
  const bare = name.replace(UNVERIFIED_SUFFIX, "");
  return { name: bare.trim(), declared: bare !== name };
}

/// `name` as the transcript draws it: bare.
export const senderName = (name: string): string => bareSender(name).name;

const word = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() ? value.trim() : undefined;

/// acpmux's sender record (a thread's or a message's `sender`), or nothing when it carries none.
export function senderRecord(value: unknown): SenderRecord | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const r = value as Record<string, unknown>;
  const verification =
    r.verification === "verified" || r.verification === "declared" || r.verification === "legacy"
      ? r.verification
      : r.authenticated === true
        ? "verified"
        : // acpmux said it could not prove the sender, with or without a declared label.
          r.labelDeclared === true || r.authenticated === false
          ? "declared"
          : undefined;
  const harness = word(r.harness);
  const relay = r.relay && typeof r.relay === "object" ? (r.relay as Record<string, unknown>) : undefined;
  const by = word(relay?.by);
  const machine = word(relay?.machine);
  const session = word(relay?.session);
  const label = word(r.label);
  const senderSession = word(r.session);
  const record: SenderRecord = {
    ...(verification && { verification }),
    ...(label && { label }),
    ...(senderSession && { session: senderSession }),
    ...(harness && { harness }),
    ...(relay && { relay: { ...(by && { by }), ...(machine && { machine }), ...(session && { session }) } }),
  };
  return Object.keys(record).length ? record : undefined;
}

/// A relay's or a machine's name as acpmux takes it (prompt_provenance.rs `harness_fits`).
const RELAY_NAME = /^[A-Za-z0-9._-]{1,64}$/;

/// Whether a prompt's provenance carries acpmux's own proof of its sender, as acpmux's sender record
/// reads it (prompt_provenance.rs `sender_record_with_auth`): a session it stamped (`fromSessionId`)
/// or a relay's record of where it took the message (`fromRelay`, its relay and machine well
/// formed). A direct transcript record carries these with no `sender` projection.
export function provenanceAuthenticated(provenance: Record<string, unknown> | undefined): boolean {
  if (!provenance) return false;
  if (word(provenance.fromSessionId)) return true;
  const relay = provenance.fromRelay;
  if (!relay || typeof relay !== "object" || Array.isArray(relay)) return false;
  const { by, machine } = relay as Record<string, unknown>;
  return typeof by === "string" && RELAY_NAME.test(by) && typeof machine === "string" && RELAY_NAME.test(machine);
}

/// Whether acpmux verified a named sender by this host's sender token (`verifiedBy: "host-token"`,
/// acpmux sender_token.rs): one of the owner's own tools, drawn by its name with no mark. Leo,
/// 2026-11-11: "generally the "unverified sender" things should be more verified".
export function hostTokenVerified(provenance: Record<string, unknown> | undefined): boolean {
  return provenance?.verified === true && provenance.verifiedBy === "host-token";
}

/// Whether the transcript marks the sender unverified: its record says it is not verified, or (an
/// older acpmux with no `verification`) its name carried the suffix.
export function senderUnverified(record: SenderRecord | undefined, declared: boolean): boolean {
  if (record?.verification) return record.verification !== "verified";
  return declared;
}
