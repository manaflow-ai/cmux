// Use as New Tab: an installed app with a New Tab view (`cmux.newtab/1`, `new_tab` on its listing
// and Installed row) is the one New Tab shows once `tabs.newTabApp` names it. The host serves that
// one setting to this page (AppsNewTabPageProvider): read it, follow it, and set it on the person's
// click. The page shows the value the host answers, never its own guess.
import { createContext, useContext, useSyncExternalStore } from "react";
import { isPageError, type PageClient } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import { userMessage } from "../shared/userMessage";
import { Badge } from "./parts";

export const NewTabOps = {
  /** `{app}`: the app id `tabs.newTabApp` names, null when unset. */
  get: "cmux.apps.newtab.get",
  /** `{app}` (an app id, or null to reset), only on the person's click; answers `{app}`. */
  set: "cmux.apps.newtab.set",
  /** `{app}` each time `tabs.newTabApp` changes, from any writer (Settings, the CLI, this page). */
  changed: "cmux.apps.newtab.changed",
} as const;

/** The host's code for a declined native sheet: the person said no, which is not an error. */
const QUIET = new Set(["cmux.page.cancelled"]);

export interface NewTabState {
  /** The app New Tab shows; undefined when unset or not read yet. */
  app?: string;
  /** The last failed change: the row it was made on, and a plain sentence. */
  error?: { app: string; sentence: string };
}

type Reply = { app?: string | null } | null | undefined;

/** `tabs.newTabApp` on the page: read on the first listener, followed live, set by the person. */
export class NewTabChoice {
  private state: NewTabState = {};
  private readonly listeners = new Set<() => void>();
  private unsubscribe?: () => void;
  private lifetime = 0;

  constructor(
    private readonly client: Pick<PageClient, "call" | "subscribe"> | null,
    initial: NewTabState = {},
  ) {
    this.state = initial;
  }

  getSnapshot = (): NewTabState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Follows the setting, then reads it once. A host without the stream still answers the read. */
  async start(): Promise<void> {
    if (!this.client || this.unsubscribe) return;
    const lifetime = ++this.lifetime;
    try {
      const unsubscribe = await this.client.subscribe<Reply>(NewTabOps.changed, (event) => {
        if (lifetime === this.lifetime) this.patch({ app: event?.app ?? undefined });
      });
      if (lifetime !== this.lifetime) return unsubscribe();
      this.unsubscribe = unsubscribe;
    } catch {
      // No live updates from this host; the read below still shows the value.
    }
    try {
      const reply = await this.client.call<Reply>(NewTabOps.get, {});
      if (lifetime === this.lifetime) this.patch({ app: reply?.app ?? undefined });
    } catch {
      // A host without the op: nothing shows as the current New Tab.
    }
  }

  stop(): void {
    ++this.lifetime;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  /** Makes `app` the one New Tab shows, or resets `tabs.newTabApp` with undefined. */
  async set(app: string | undefined, row = app ?? this.state.app ?? ""): Promise<void> {
    if (!this.client) return;
    try {
      const reply = await this.client.call<Reply>(NewTabOps.set, { app: app ?? null });
      this.patch({ app: reply?.app ?? undefined, error: undefined });
    } catch (error) {
      if (!(isPageError(error) && QUIET.has(error.code)))
        this.patch({ error: { app: row, sentence: userMessage(error) } });
    }
  }

  private patch(patch: Partial<NewTabState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

const NewTabContext = createContext<NewTabChoice | null>(null);

/** The page's one `NewTabChoice` (main.tsx); without it the controls draw nothing. */
export const NewTabChoiceProvider = NewTabContext.Provider;

const NONE: NewTabState = {};
const noSubscription = () => () => {};

function useNewTabChoice(): { choice: NewTabChoice | null; state: NewTabState } {
  const choice = useContext(NewTabContext);
  const state = useSyncExternalStore(
    choice?.subscribe ?? noSubscription,
    choice?.getSnapshot ?? (() => NONE),
    choice?.getSnapshot ?? (() => NONE),
  );
  return { choice, state };
}

/**
 * An installed app's New Tab controls: Use as New Tab on an app with a New Tab view; on the app New
 * Tab shows now, the quiet On New Tab label and Stop Using as New Tab. Nothing for any other app.
 */
export function UseAsNewTab({ app, strings }: { app: { id: string; new_tab?: boolean }; strings: Strings }) {
  const { choice, state } = useNewTabChoice();
  if (!app.new_tab || !choice) return null;
  return (
    <NewTabControls
      app={app.id}
      current={state.app === app.id}
      error={state.error?.app === app.id ? state.error.sentence : undefined}
      onSet={(id) => void choice.set(id, app.id)}
      strings={strings}
    />
  );
}

/** The controls without the page's state, for one app. */
export function NewTabControls({
  app,
  current,
  error,
  onSet,
  strings,
}: {
  app: string;
  current: boolean;
  error?: string;
  onSet: (app: string | undefined) => void;
  strings: Strings;
}) {
  const { t } = strings;
  return (
    <>
      {current && <Badge text={t("store.badge.onNewTab")} />}
      {error && <span className="apps-failure selectable">{error}</span>}
      <button
        type="button"
        className="apps-button"
        data-new-tab-action={current ? "stop" : "use"}
        onClick={(event) => {
          event.stopPropagation();
          onSet(current ? undefined : app);
        }}
      >
        {t(current ? "store.action.stopNewTab" : "store.action.useAsNewTab")}
      </button>
    </>
  );
}
