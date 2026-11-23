// Extension slash commands (`cmux.composer.command/1`) in the composer's `/` menu. The daemon
// decides which there are (cmux-tui-core apps/composer.rs, `apps.composer.list`, through the page
// host's `cmux.apps.panels.composer`); this file only reads its answer, lists it again when the
// installed apps change (`cmux.apps.panels.changed`: an install, a hide, a save of a local
// extension's manifest), and puts the rows after cmux's and the agent's own.
import { useMemo, useSyncExternalStore } from "react";
import type { PageClient } from "../../../pages/shared/pageClient";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { pageHostClient } from "../pageHost";
import type { SlashCommand } from "../slashCommands";

const EMPTY: readonly SlashCommand[] = [];

/// The commands in an `apps.composer.list` reply; an entry with no name or no text is dropped.
export function extensionCommandsFrom(reply: unknown): SlashCommand[] {
  const commands = (reply as { commands?: unknown } | null)?.commands;
  if (!Array.isArray(commands)) return [];
  const out: SlashCommand[] = [];
  for (const entry of commands) {
    if (!entry || typeof entry !== "object") continue;
    const { name, insert, description, hint, extension } = entry as Record<string, unknown>;
    if (typeof name !== "string" || !name || typeof insert !== "string" || !insert) continue;
    out.push({
      name,
      insert,
      description: typeof description === "string" ? description : "",
      ...(typeof hint === "string" && hint && { hint }),
      ...(typeof extension === "string" && extension && { extension }),
      source: "extension",
    });
  }
  return out;
}

/// `commands` with the extension commands after them; a name cmux or the agent already has stays
/// theirs, so one `/name` never means two things.
export function withExtensionCommands(
  commands: readonly SlashCommand[],
  extension: readonly SlashCommand[],
): SlashCommand[] {
  if (!extension.length) return commands as SlashCommand[];
  const taken = new Set(commands.map((command) => command.name.toLowerCase()));
  return [...commands, ...extension.filter((command) => !taken.has(command.name.toLowerCase()))];
}

/// All composer places use one list and one change subscription per page client.
export class ComposerContributions {
  private reply: unknown = null;
  private readonly listeners = new Set<() => void>();
  private reading = 0;
  private watch = 0;
  private active = false;
  private stopWatch?: () => void;

  constructor(private readonly client: PageClient | null) {}

  getSnapshot = (): unknown => this.reply;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    this.start();
    return () => {
      this.listeners.delete(listener);
      if (!this.listeners.size) this.stop();
    };
  };

  start(): void {
    if (this.active || !this.client) return;
    this.active = true;
    const watch = ++this.watch;
    void this.client
      .subscribe("cmux.apps.panels.changed", () => void this.refresh())
      .then((stop) => {
        if (!this.active || watch !== this.watch) stop();
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
    this.reply = null;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const reading = ++this.reading;
    const next = await this.client.call("cmux.apps.panels.composer", {}).catch(() => null);
    if (!this.active || reading !== this.reading || JSON.stringify(next) === JSON.stringify(this.reply)) return;
    this.reply = next;
    for (const listener of this.listeners) listener();
  }
}

const pageOwners = new WeakMap<PageClient, ComposerContributions>();
const offline = new ComposerContributions(null);

function contributions(client: PageClient | null): ComposerContributions {
  if (!client) return offline;
  const existing = pageOwners.get(client);
  if (existing) return existing;
  const owner = new ComposerContributions(client);
  pageOwners.set(client, owner);
  return owner;
}

export function useComposerContribution<T>(
  read: (reply: unknown) => T,
  empty: T,
  injectedClient?: PageClient | null,
): T {
  const client = injectedClient === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injectedClient;
  const owner = contributions(client);
  const reply = useSyncExternalStore(owner.subscribe, owner.getSnapshot, owner.getSnapshot);
  return useMemo(() => (reply == null ? empty : read(reply)), [reply, read, empty]);
}

export function useExtensionCommands(injectedClient?: PageClient | null): readonly SlashCommand[] {
  return useComposerContribution<readonly SlashCommand[]>(extensionCommandsFrom, EMPTY, injectedClient);
}
