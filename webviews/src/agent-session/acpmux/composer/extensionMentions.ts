// Extension mentions (`cmux.composer.mention/1`) in the composer's `@` menu. An extension names a
// prefix (`pr`) and its items in its manifest; the daemon matches and ranks them
// (cmux-tui-core apps/composer.rs, `apps.composer.mentions`, through the page host's
// `cmux.apps.panels.mentions`). This file knows which prefixes exist (`apps.composer.list`, read again
// when the installed apps change), asks for the items of the word being typed, and keeps the newest
// answer. `@pr` or `@pr:441` narrows the menu to that provider; any other word asks every provider.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { pageHostClient } from "../pageHost";

/// One item an extension offers after `@`, as the daemon answers it.
export type ExtensionMention = {
  app: string;
  extension: string;
  prefix: string;
  id: string;
  label: string;
  detail?: string;
  insert: string;
};

const NONE: readonly ExtensionMention[] = [];
const NO_PREFIXES: readonly string[] = [];

/// The prefixes of the mention providers in an `apps.composer.list` reply.
export function mentionPrefixesFrom(reply: unknown): string[] {
  const mentions = (reply as { mentions?: unknown } | null)?.mentions;
  if (!Array.isArray(mentions)) return [];
  const out: string[] = [];
  for (const entry of mentions) {
    const prefix = (entry as { prefix?: unknown } | null)?.prefix;
    if (typeof prefix === "string" && prefix && !out.includes(prefix)) out.push(prefix);
  }
  return out;
}

/// The items in an `apps.composer.mentions` reply; an entry with no id or label is dropped, and
/// one with no insert text writes its label.
export function extensionMentionsFrom(reply: unknown): ExtensionMention[] {
  const mentions = (reply as { mentions?: unknown } | null)?.mentions;
  if (!Array.isArray(mentions)) return [];
  const out: ExtensionMention[] = [];
  for (const entry of mentions) {
    if (!entry || typeof entry !== "object") continue;
    const { app, extension, prefix, id, label, detail, insert } = entry as Record<string, unknown>;
    if (typeof id !== "string" || !id || typeof label !== "string" || !label) continue;
    out.push({
      app: typeof app === "string" ? app : "",
      extension: typeof extension === "string" ? extension : "",
      prefix: typeof prefix === "string" ? prefix : "",
      id,
      label,
      ...(typeof detail === "string" && detail && { detail }),
      insert: typeof insert === "string" && insert ? insert : label,
    });
  }
  return out;
}

/// What an `@word` asks the providers: `pr:441` and `pr` (a provider's prefix as the whole word)
/// ask that provider only, for `441` and for everything; any other word asks every provider for it.
export function mentionAsk(word: string, prefixes: readonly string[]): { query: string; prefix?: string } {
  const colon = word.indexOf(":");
  if (colon > 0) {
    const prefix = word.slice(0, colon).toLowerCase();
    if (prefixes.includes(prefix)) return { prefix, query: word.slice(colon + 1) };
  }
  const lower = word.toLowerCase();
  if (prefixes.includes(lower)) return { prefix: lower, query: "" };
  return { query: word };
}

/// One page's mention providers: their prefixes, read on start and on every change of the
/// installed apps.
export class ExtensionMentionProviders {
  private snapshot: readonly string[] = NO_PREFIXES;
  private readonly listeners = new Set<() => void>();
  private reading = 0;
  private active = false;
  private stopWatch?: () => void;

  constructor(readonly client: PageClient | null) {}

  getSnapshot = (): readonly string[] => this.snapshot;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  start(): void {
    if (this.active || !this.client) return;
    this.active = true;
    void this.client
      .subscribe("cmux.apps.panels.changed", () => void this.refresh())
      .then((stop) => {
        if (!this.active) stop();
        else {
          this.stopWatch = stop;
          void this.refresh();
        }
      })
      .catch(() => undefined);
    void this.refresh();
  }

  stop(): void {
    this.active = false;
    ++this.reading;
    this.stopWatch?.();
    this.stopWatch = undefined;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const reading = ++this.reading;
    let next: string[];
    try {
      next = mentionPrefixesFrom(await this.client.call("cmux.apps.panels.composer", {}));
    } catch {
      next = [];
    }
    if (!this.active || reading !== this.reading) return;
    if (next.length === this.snapshot.length && next.every((prefix, index) => prefix === this.snapshot[index])) return;
    this.snapshot = next.length ? next : NO_PREFIXES;
    for (const listener of this.listeners) listener();
  }
}

function mentionClient(injected: PageClient | null | undefined): PageClient | null {
  return injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
}

/// The prefixes of the installed mention providers (none: an `@` opens no menu for them).
export function useExtensionMentionPrefixes(injectedClient?: PageClient | null): readonly string[] {
  const client = mentionClient(injectedClient);
  const owner = useMemo(() => new ExtensionMentionProviders(client), [client]);
  useEffect(() => {
    owner.start();
    return () => owner.stop();
  }, [owner]);
  return useSyncExternalStore(owner.subscribe, owner.getSnapshot, owner.getSnapshot);
}

/// The extension items for the `@word` being typed (undefined: no menu), the newest answer only.
export function useExtensionMentions(
  word: string | undefined,
  prefixes: readonly string[],
  injectedClient?: PageClient | null,
): readonly ExtensionMention[] {
  const client = mentionClient(injectedClient);
  const [found, setFound] = useState<{ items: readonly ExtensionMention[] }>({ items: NONE });
  useEffect(() => {
    if (word === undefined || !prefixes.length || !client) return;
    let current = true;
    const ask = mentionAsk(word.trim(), prefixes);
    client.call("cmux.apps.panels.mentions", ask).then(
      (reply) => current && setFound({ items: extensionMentionsFrom(reply) }),
      () => current && setFound({ items: NONE }),
    );
    return () => {
      current = false;
    };
  }, [client, word, prefixes]);
  // The last answer stays while the next one is on its way, so the rows do not blink per key.
  return word !== undefined && prefixes.length ? found.items : NONE;
}
