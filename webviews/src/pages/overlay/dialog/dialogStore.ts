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

  edit(id: number, values: Record<string, DialogValue>) {
    void this.client.call("cmux.overlay.dialog.edit", { id, values }).catch(() => {});
  }

  press(id: number, button: string, values: Record<string, DialogValue>) {
    void this.client.call("cmux.overlay.dialog.press", { id, button, values }).catch(() => {});
  }

  layout(id: number, card: { x: number; y: number; w: number; h: number }) {
    void this.client.call("cmux.overlay.dialog.layout", { id, card }).catch(() => {});
  }
}
