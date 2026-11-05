// The recap card above the composer (Claude desktop's end-of-turn card, its 10-14 release): when
// the last turn completed by asking the person something ("Should I open a PR for this?"), the
// card shows the answer's last paragraph, the question, and its yes one click (or ⌘Return on an
// empty composer) away. Not now and × hide it for that turn, kept per chat in the page's storage.
// Behind the agent.sessionStatus Debug toggle.
import { useMemo, useState } from "react";
import { Close } from "./conversation/icons";
import { useT } from "./i18n";
import { Keycap } from "./Keycap";
import type { AcpmuxRow } from "./model";
import { recapFrom, type Recap } from "./recap";

/** The turns whose cards a chat keeps hidden: the newest few are enough. */
const KEPT = 20;
const storageKey = (sessionId: string) => `acpmux.recap.dismissed.${sessionId}`;

function readDismissed(sessionId: string | undefined): string[] {
  if (!sessionId) return [];
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey(sessionId)) ?? "[]");
    return Array.isArray(value) ? value.filter((key): key is string => typeof key === "string") : [];
  } catch {
    return [];
  }
}

function writeDismissed(sessionId: string | undefined, keys: readonly string[]): void {
  if (!sessionId) return;
  try {
    localStorage.setItem(storageKey(sessionId), JSON.stringify(keys));
  } catch {
    // Without storage the card stays hidden until the page reloads.
  }
}

export type RecapCardState = {
  /** The card to show now, if any. */
  recap: Recap | undefined;
  /** The card's yes was not sent: the card is back with a note saying so. */
  failed: boolean;
  /** Sends the card's yes and hides it. */
  reply(): void;
  /** Hides the card for its turn. */
  dismiss(): void;
};

/// The chat's recap card: `on` while the agent.sessionStatus Debug toggle is on and nothing runs or
/// waits for the person.
/// `send` sends a prompt as the composer does; `focusComposer` takes the keyboard back after.
export function useRecapCard({
  rows,
  sessionId,
  on,
  asking,
  send,
  focusComposer,
}: {
  rows: readonly AcpmuxRow[];
  sessionId: string | undefined;
  on: boolean;
  asking: boolean;
  send(text: string): Promise<void>;
  focusComposer(): void;
}): RecapCardState {
  // Every streamed chunk is a new rows array, but `on` is false while a turn runs.
  const found = useMemo(() => (on ? recapFrom(rows, { asking }) : null), [on, rows, asking]);
  const [dismissed, setDismissed] = useState(() => ({ sessionId, keys: readDismissed(sessionId) }));
  // Another chat reads its own hidden cards once, as it shows.
  let current = dismissed;
  if (current.sessionId !== sessionId) {
    current = { sessionId, keys: readDismissed(sessionId) };
    setDismissed(current);
  }
  const recap = found && !current.keys.includes(found.key) ? found : undefined;
  // The card whose yes did not go, by its turn's key.
  const [failedKey, setFailedKey] = useState<string | undefined>();
  const hide = (key: string) => setDismissed({ sessionId, keys: withKey(current.keys, key) });
  return {
    recap,
    failed: recap !== undefined && recap.key === failedKey,
    reply() {
      if (!recap) return;
      const { key } = recap;
      // Hidden while its yes is on the way; kept hidden once sent, and back with a note if the send failed.
      hide(key);
      setFailedKey(undefined);
      send(recap.reply).then(
        () => writeDismissed(sessionId, withKey(readDismissed(sessionId), key)),
        () => {
          setFailedKey(key);
          setDismissed((now) =>
            now.sessionId === sessionId ? { sessionId, keys: now.keys.filter((kept) => kept !== key) } : now,
          );
        },
      );
      focusComposer();
    },
    dismiss() {
      if (!recap) return;
      hide(recap.key);
      writeDismissed(sessionId, withKey(readDismissed(sessionId), recap.key));
      focusComposer();
    },
  };
}

/// `keys` with `key` last, the newest KEPT of them.
const withKey = (keys: readonly string[], key: string) => [...keys.filter((kept) => kept !== key), key].slice(-KEPT);

/// The card: summary (muted, at most three lines), the question, a note when its yes was not sent,
/// then Yes and Not now.
/// `keyHint`: ⌘Return on the composer answers yes (not in the Quick Composer, whose ⌘Return opens a window,
/// nor in shell mode).
export function RecapCard({
  recap,
  onReply,
  onDismiss,
  keyHint,
  failed = false,
}: {
  recap: Recap;
  onReply(): void;
  onDismiss(): void;
  keyHint: boolean;
  /** The last yes was not sent. */
  failed?: boolean;
}) {
  const t = useT();
  const yes = recap.action ? t("recap.yesAction", { action: recap.action }) : t("recap.yes");
  return (
    <section className="acpmux-recap" aria-label={t("recap.label")}>
      <div className="acpmux-recap__card">
        {recap.summary && <p className="acpmux-recap__summary">{recap.summary}</p>}
        <p className="acpmux-recap__question">{recap.question}</p>
        {failed && (
          <p className="acpmux-recap__error" role="alert">
            {t("recap.sendFailed")}
          </p>
        )}
        <div className="acpmux-recap__actions">
          <button
            type="button"
            className="acpmux-recap__button acpmux-recap__yes"
            aria-keyshortcuts={keyHint ? "Meta+Enter" : undefined}
            onClick={onReply}
          >
            {yes}
            {keyHint && <Keycap>⌘↩</Keycap>}
          </button>
          <button type="button" className="acpmux-recap__button acpmux-recap__later" onClick={onDismiss}>
            {t("recap.notNow")}
          </button>
        </div>
        <button
          type="button"
          className="cv-iconbtn cv-iconbtn--compact acpmux-recap__dismiss"
          aria-label={t("recap.dismiss")}
          onClick={onDismiss}
        >
          <Close size={12} />
        </button>
      </div>
    </section>
  );
}
