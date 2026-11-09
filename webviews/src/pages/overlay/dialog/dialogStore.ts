// The dialog the host streams to this overlay page (`cmux.overlay.dialog.state`), and the calls back.
import type { PageClient } from "../../shared/pageClient";
import type { DialogStream, DialogState, DialogValue } from "./types";

export class DialogStore {
  private current: DialogState | null = null;
  private listeners = new Set<() => void>();

  constructor(private readonly client: PageClient) {}

  async start(): Promise<void> {
    await this.client.subscribe<DialogStream>("cmux.overlay.dialog.state", (data) => {
      this.current = data.dialog;
      for (const listener of this.listeners) listener();
    });
  }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly snapshot = () => this.current;

  // `serial` is the values serial the page's values stand on: the host ignores values sent against older ones.
  edit(id: number, serial: number, values: Record<string, DialogValue>) {
    void this.client.call("cmux.overlay.dialog.edit", { id, serial, values }).catch(() => {});
  }

  press(id: number, serial: number, button: string, values: Record<string, DialogValue>) {
    void this.client.call("cmux.overlay.dialog.press", { id, serial, button, values }).catch(() => {});
  }

  painted(id: number) {
    void this.client.call("cmux.overlay.dialog.painted", { id }).catch(() => {});
  }

  layout(id: number, card: { x: number; y: number; w: number; h: number }) {
    void this.client.call("cmux.overlay.dialog.layout", { id, card }).catch(() => {});
  }
}
