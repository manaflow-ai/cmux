// "Fork to New Chief" on a message (MessageActions): a new Chief that starts from a Chief's memory
// cut right after that message (`chief.profile.create` with `fork`; the daemon copies the memory,
// cmux-tui server/chief_fork.rs). These are the page's pure parts: which Chief a message forks, the
// new Chief's default name, the create's fields, and the line the new Chief's chat shows about
// where it came from. The create itself is the person's click through the host (HomeSheets).
import type { Strings } from "../shared/i18n";
import type { HomeChief, HomeConversation, HomeMessage } from "./types";

/** display_name holds at most 100 characters. */
const NAME_MAX = 100;

/**
 * The Chief a fork at `message` copies, or undefined when there is none to fork here.
 *
 * A message by a Chief forks that Chief. Any other message forks the conversation's one Chief; a
 * conversation with several Chiefs forks only from a Chief's own message (which Chief's memory a
 * person's message belongs to is not one answer). Only this Mac's conversations: the Cloud Chief's
 * memory is on the hosted brain, which has no fork yet.
 */
export function forkTarget(
  conversation: HomeConversation | undefined,
  message: HomeMessage,
  chiefs: ReadonlyMap<string, HomeChief>,
): HomeChief | undefined {
  if (!conversation || conversation.owner !== "local" || message.retracted) return undefined;
  const author = chiefs.get(message.author);
  if (author) return author;
  const here = conversation.participants.filter((p) => p.chief && chiefs.has(p.id));
  return here.length === 1 ? chiefs.get(here[0]!.id) : undefined;
}

/** The new Chief's name: "<source> fork", within the record's 100 characters. */
export function forkName(source: HomeChief, strings: Strings): string {
  const name = strings.format("chief.forkName", source.name.trim() || "Chief");
  // The daemon counts Unicode scalar values (Rust `chars()`), as Array.from does.
  const scalars = Array.from(name);
  return scalars.length <= NAME_MAX ? name : scalars.slice(0, NAME_MAX).join("");
}

/** `chief.profile.create`'s fields for a fork of `source` at `message`. */
export function forkFields(source: HomeChief, message: HomeMessage, strings: Strings): Record<string, unknown> {
  return {
    display_name: forkName(source, strings),
    fork: { chief: source.id, conversation: message.conversation, seq: message.seq },
  };
}

/** What the forked Chief's chat says about where it came from; undefined for a Chief made blank. */
export function forkOriginText(chief: HomeChief | undefined, strings: Strings): string | undefined {
  const origin = chief?.forkedFrom;
  if (!origin) return undefined;
  return origin.seq !== undefined
    ? strings.format("fork.origin.message", origin.name, String(origin.seq))
    : strings.format("fork.origin.now", origin.name);
}
