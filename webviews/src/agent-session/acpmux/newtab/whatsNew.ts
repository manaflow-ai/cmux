// What's New in the New Tab page's top-right corner, as the host pushes it (`whatsNew`,
// CmuxNextAgentPane AgentPaneWhatsNew): after an update, the line that tells you cmux updated and
// opens what changed. It took the sidebar's Updated card's place (Leo 2026-11-24: "the what's new
// only on the top right of the new tab page just like claude code"). Every string comes localized
// from the host; null while there is nothing new. A module store like nowPlaying.ts, so a push that
// arrives before the screen mounts is kept.
import { useSyncExternalStore } from "react";

/// How the corner draws: `link` the sparkle and What's New (the default), `titled` the update's own
/// line before it ("Updated to Nightly · What's New"), `dot` the sparkle alone. Only the gallery picks
/// one; the host sends none.
export type WhatsNewLook = "link" | "titled" | "dot";

export type WhatsNewNotice = {
  /// "Updated to Nightly": the tooltip, and the titled look's lead.
  title: string;
  /// "What's New": the button.
  whatsNew: string;
  /// The x's label ("Dismiss").
  dismiss: string;
  look: WhatsNewLook;
};

export type WhatsNewCommand = "open" | "dismiss";

let notice: WhatsNewNotice | null = null;
const listeners = new Set<() => void>();

function line(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, 120) : undefined;
}

/// Replaces the notice from a host push; anything malformed clears it.
export function setWhatsNew(value: unknown): void {
  const raw = value as Record<string, unknown> | null;
  const whatsNew = raw && typeof raw === "object" ? line(raw.whatsNew) : undefined;
  if (!raw || !whatsNew) {
    notice = null;
  } else {
    const look = raw.look === "titled" || raw.look === "dot" ? raw.look : "link";
    notice = { title: line(raw.title) ?? whatsNew, whatsNew, dismiss: line(raw.dismiss) ?? "Dismiss", look };
  }
  for (const listener of listeners) listener();
}

export function whatsNewNotice(): WhatsNewNotice | null {
  return notice;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useWhatsNew(): WhatsNewNotice | null {
  return useSyncExternalStore(subscribe, whatsNewNotice, whatsNewNotice);
}
