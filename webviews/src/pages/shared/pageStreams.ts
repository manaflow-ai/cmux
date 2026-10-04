// The two streams every page gets from its host (the Settings lead's page pattern, adopted for all
// pages): `cmux.page.connection {connected}`, the owner link, and `cmux.page.command {command,
// text?}`, the app key dispatcher's page commands. A page never reads Cmd/Ctrl chords itself.
import { isPageError, type PageClient } from "./pageClient";

export const PAGE_COMMAND = "cmux.page.command";
export const PAGE_CONNECTION = "cmux.page.connection";
/** The error code of a lost link to the owner or the host. */
export const LINK_CLOSED = "cmux.protocol.closed";

export type PageCommandName = "find" | "focusSearch" | "back" | "forward" | "reset";

export interface PageCommand {
  command: PageCommandName;
  text?: string;
}

export interface PageStreamHandlers {
  onConnection?: (connected: boolean) => void;
  onCommand?: (command: PageCommand) => void;
}

/** Subscribes to the page streams a host serves; a host without one (an old host, a mock) is fine. */
export async function subscribePageStreams(client: PageClient, handlers: PageStreamHandlers): Promise<() => void> {
  const stops: Array<() => void> = [];
  const tolerate = async (start: () => Promise<() => void>) => {
    try {
      stops.push(await start());
    } catch (error) {
      if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op")) throw error;
    }
  };
  if (handlers.onConnection) {
    const onConnection = handlers.onConnection;
    await tolerate(() =>
      client.subscribe<{ connected: boolean }>(PAGE_CONNECTION, (data) => onConnection(data.connected === true)),
    );
  }
  if (handlers.onCommand) {
    const onCommand = handlers.onCommand;
    await tolerate(() => client.subscribe<PageCommand>(PAGE_COMMAND, (data) => onCommand(data)));
  }
  return () => stops.forEach((stop) => stop());
}

/** The page streams for in-memory mock providers (dev loop and tests). */
export class MockPageStreams {
  private connected = true;
  private readonly connection = new Set<(data: unknown, seq: number) => void>();
  private readonly commands = new Set<(data: unknown, seq: number) => void>();
  private seq = 0;

  /** Handles a subscribe for a page stream; null for any other stream. */
  subscribe(stream: string, onEvent: (data: unknown, seq: number) => void): (() => void) | null {
    if (stream === PAGE_CONNECTION) {
      this.connection.add(onEvent);
      queueMicrotask(() => onEvent({ connected: this.connected }, ++this.seq));
      return () => void this.connection.delete(onEvent);
    }
    if (stream === PAGE_COMMAND) {
      this.commands.add(onEvent);
      return () => void this.commands.delete(onEvent);
    }
    return null;
  }

  /** The dispatcher sends a page command; false when no page code listens. */
  command(command: PageCommand): boolean {
    for (const listener of this.commands) listener(command, ++this.seq);
    return this.commands.size > 0;
  }

  setConnected(connected: boolean): void {
    if (connected === this.connected) return;
    this.connected = connected;
    for (const listener of this.connection) listener({ connected }, ++this.seq);
  }
}
