import { SubsessionStore } from "../subagents/subsessions";
import { senderLabel } from "./incomingMessageCardModel";

/// How the line reads. `sentence`, the default: "Sent to tests", then the first line muted
/// (Leo 2026-10-24: "sending message or sent message to X or Y"). The others are gallery versions
/// kept beside it (SentMessageLine.gallery.ts): `arrow`, "→ tests: <first line>" (#24977's line),
/// and `quote`, "Sent to tests: “<first line>”". The native host sends no value.
export type SentLook = "sentence" | "arrow" | "quote";

const LOOKS: readonly SentLook[] = ["sentence", "arrow", "quote"];
export let look: SentLook = "sentence";
export const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureSentLook(value: unknown): void {
  const next = LOOKS.find((one) => one === value) ?? "sentence";
  if (next === look) return;
  look = next;
  for (const listener of listeners) listener();
}

/// The listed chat a send's target names: its id when the call gives it, else the chat with that
/// name, on that host for `host/name` or `host:name` (a basket such as `reports:leo` is no chat).
export function targetChat(store: SubsessionStore, target: string, sessionId?: string): string | undefined {
  if (sessionId) return store.has(sessionId) ? sessionId : undefined;
  // A peer's chat is listed as `host/name` (acpmux hub/peers.rs); a send may name a chat by its id.
  const listed = store.find(target);
  if (listed) return listed;
  if (store.has(target)) return target;
  const split = /^([^/:]+)[/:](.+)$/.exec(target);
  if (!split) return undefined;
  const id = store.find(`${split[1]}/${split[2]}`) ?? store.find(split[2]!);
  return id && (store.find(`${split[1]}/${split[2]}`) === id || store.host(id) === split[1]) ? id : undefined;
}

/// A message's disclosure and React key: the call's id, and for one message of a batch its place
/// in the batch, so each message of one call opens on its own.
export function sendKey(id: string, index?: number): string {
  return index === undefined ? id : `${id}#${index}`;
}

/// A recipient's name and the machine it runs on, as a received message's sender reads
/// (IncomingMessageCard.tsx `senderLabel`): `host/name` and `host:name` name a peer's chat, and the
/// listed chat's own machine names it otherwise. A basket (`reports:leo`) is no machine's.
export function recipientPlace(target: string, listedHost: string | undefined): { name: string; host?: string } {
  const split = /^([^/:\s]+)[/:](.+)$/.exec(target.trim());
  if (listedHost) {
    const name = senderLabel(split && split[1] === listedHost ? split[2]! : target, listedHost);
    return { name, host: listedHost };
  }
  if (split && target.includes("/")) return { name: split[2]!, host: split[1] };
  return { name: target };
}
