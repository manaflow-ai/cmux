// Extension slash commands (`cmux.composer.command/1`) in the composer's `/` menu. The daemon
// decides which there are (cmux-tui-core apps/composer.rs, `apps.composer.list`, through the page
// host's `cmux.apps.panels.composer`); this file only reads its answer, lists it again when the
// installed apps change (`cmux.apps.panels.changed`: an install, a hide, a save of a local
// extension's manifest), and puts the rows after cmux's and the agent's own.
import { useEffect, useMemo, useSyncExternalStore } from "react";
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

/// One page's extension commands: read on start and again on every change of the installed apps.
export class ExtensionCommands {
  private snapshot: readonly SlashCommand[] = EMPTY;
  private readonly listeners = new Set<() => void>();
  private reading = 0;
  private active = false;
  private stopWatch?: () => void;

  constructor(private readonly client: PageClient | null) {}

  getSnapshot = (): readonly SlashCommand[] => this.snapshot;
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
          // A change between the first read and the watch would be missed: read once more.
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
    let next: SlashCommand[];
    try {
      next = extensionCommandsFrom(await this.client.call("cmux.apps.panels.composer", {}));
    } catch {
      // An older host serves no composer places: the menu has none, with no error.
      next = [];
    }
    if (!this.active || reading !== this.reading) return;
    const same =
      next.length === this.snapshot.length &&
      next.every((command, index) => {
        const old = this.snapshot[index]!;
        return (
          old.name === command.name &&
          old.insert === command.insert &&
          old.description === command.description &&
          old.hint === command.hint &&
          old.extension === command.extension
        );
      });
    if (same) return;
    this.snapshot = next.length ? next : EMPTY;
    for (const listener of this.listeners) listener();
  }
}

/// The page's extension commands, kept current while the page is open.
export function useExtensionCommands(injectedClient?: PageClient | null): readonly SlashCommand[] {
  const client = injectedClient === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injectedClient;
  const owner = useMemo(() => new ExtensionCommands(client), [client]);
  const commands = useSyncExternalStore(owner.subscribe, owner.getSnapshot, owner.getSnapshot);
  useEffect(() => {
    owner.start();
    return () => owner.stop();
  }, [owner]);
  return commands;
}
