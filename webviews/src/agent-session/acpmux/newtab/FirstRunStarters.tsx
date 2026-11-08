// Starter tasks under the New Tab composer on a first run: while this Mac has no chats at all, three
// quiet rows name things to ask an agent, so the first page is never a blank field with nothing to
// try. A pick puts its words in the composer and sends nothing; the first chat makes the rows go
// away for good (there is nothing to dismiss or turn off). Rows are plain text with an icon; only a
// hovered or focused row draws a wash (StageCards' rule), never a resting pill.
import { Icon } from "../icons/Icon";
import type { AcpmuxSnapshot } from "../model";
import { useNt, type NewTabStringKey } from "./strings";

/// The starters, in order: each one's label is also the prompt it puts in the composer.
export const FIRST_RUN_STARTERS = [
  { id: "explain", icon: "folder", label: "starters.explain" },
  { id: "fix", icon: "terminal", label: "starters.fix" },
  { id: "review", icon: "agent.chat", label: "starters.review" },
] as const satisfies readonly { id: string; icon: string; label: NewTabStringKey }[];

export type FirstRunStarterLook = "rows" | "inline" | "card";

/// Whether the page shows the starters: a first run is a Mac with no chats, local or on a peer, once
/// the daemon connection has listed the chats (`chatsPending` off: before that an empty list proves
/// nothing, and a cached catalog can arrive first) and an agent is there to ask (the catalog), on the
/// page's own New Tab rather than All chats. Chats the host indexed on this device (`deviceChats`,
/// shown as recent chats) count too: a Mac with that history is not a first run. Typing keeps them: they leave only with the page (a
/// chat started here) or once a chat exists, so nothing under the composer jumps while it is edited.
export function showsFirstRunStarters(
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "catalog">,
  {
    allChats,
    chatsPending = false,
    deviceChats = 0,
  }: { allChats: boolean; chatsPending?: boolean; deviceChats?: number },
): boolean {
  return (
    !allChats && !chatsPending && deviceChats === 0 && snapshot.catalog.length > 0 && snapshot.sessions.length === 0
  );
}

export function FirstRunStarters({
  look = "rows",
  onPick,
}: {
  look?: FirstRunStarterLook;
  /// Puts the starter's words in the composer (and focuses it); never sends.
  onPick(prompt: string): void;
}) {
  const nt = useNt();
  return (
    <section className="nt-starters" data-look={look} aria-label={nt("starters.label")}>
      <span className="nt-starters-label">{nt("starters.label")}</span>
      <div className="nt-starters-list">
        {FIRST_RUN_STARTERS.map((starter) => {
          const prompt = nt(starter.label);
          return (
            <button
              key={starter.id}
              type="button"
              className="nt-starter"
              data-starter={starter.id}
              onClick={() => onPick(prompt)}
            >
              {look !== "inline" && (
                <span className="nt-starter-icon" aria-hidden="true">
                  <Icon name={starter.icon} size={14} />
                </span>
              )}
              <span className="nt-starter-text">{prompt}</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}
