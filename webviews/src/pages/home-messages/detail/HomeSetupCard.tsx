// The Set Up cmux card on the Messages page (cmux#37736 round 9 F1): the first-run card the native Chief
// chat hosted (CmuxNextApp HomeHostView+SetupCard; #39240, #39270, #39388), pinned under the header of a
// Chief's chat while the host's FirstRunSetup shows it (a first run, until Hide or every row done); no
// card in any other conversation. The host (CmuxNextOnboarding SetupCardRoute) serves the setup-card
// page's own `cmux.setup.*` under this page's prefix: the same rows, actions, words and dismissal.
import { useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react";
import type { PageClient } from "../../shared/pageClient";
import { SetupCardStore } from "../../setup-card/store";
import { SetupCard } from "../cards/setup/SetupCard";
import type { SetupState } from "../cards/setup/setupModel";
import type { Strings } from "../cards/strings";
import { useHostStream } from "./detailHost";

const PREFIX = "cmux.home.messages.setup.";

export const HOME_SETUP_OPS = {
  /** Stream and call: `{shows}`, whether the card shows now; sent on subscribe and on every change. */
  shows: `${PREFIX}shows`,
  /** `{}` → `SetupState`. */
  state: `${PREFIX}state`,
  /** Stream: the whole `SetupState` after each change. */
  changed: `${PREFIX}changed`,
  /** `{action}`: a row's button, on the person's own click only. */
  run: `${PREFIX}run`,
  /** `{}`: Hide; the card leaves for good, on the person's own click only. */
  hide: `${PREFIX}hide`,
  /** `{}`: the page gained focus (back from a sign-in): the host checks the sign-ins again. */
  focused: `${PREFIX}focused`,
} as const;

export const parseSetupShows = (event: unknown): boolean =>
  !!event && typeof event === "object" && (event as { shows?: unknown }).shows === true;

const noSubscribe = () => () => {};
const noState = (): SetupState | null => null;

/** The card for the open conversation, or undefined: none outside a Chief's chat, before the host says it
 * shows, or before its first state. */
export function useSetupCard(host: PageClient | null, isChief: boolean, strings: Strings): ReactNode | undefined {
  const shows = useHostStream(host, HOME_SETUP_OPS.shows, parseSetupShows, false);
  const active = !!host && isChief && shows;
  const store = useMemo(() => (active && host ? new SetupCardStore(host, HOME_SETUP_OPS) : undefined), [active, host]);
  useEffect(() => {
    if (!store) return;
    void store.start();
    const onFocus = () => store.send(HOME_SETUP_OPS.focused, {});
    window.addEventListener("focus", onFocus);
    return () => {
      window.removeEventListener("focus", onFocus);
      store.stop();
    };
  }, [store]);
  const state = useSyncExternalStore(
    store?.subscribe ?? noSubscribe,
    store?.getSnapshot ?? noState,
    store?.getSnapshot ?? noState,
  );
  if (!store || !state) return undefined;
  return (
    <div className="hm-setup-pinned">
      <SetupCard
        strings={strings}
        state={state}
        look="rows"
        onAction={(action) => store.send(HOME_SETUP_OPS.run, { action })}
        onHide={() => store.send(HOME_SETUP_OPS.hide, {})}
      />
    </div>
  );
}
