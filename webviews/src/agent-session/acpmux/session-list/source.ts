import { postNative } from "../native";
import { listenForSessionList, removeSessionListHost } from "./receiver";
import { SessionListHost, type SessionListOpen, type SessionListPost } from "./host";
import type { SessionListBatch, SessionListSnapshot } from "./store";

export type SessionListSourceHooks = {
  changed(snapshot: SessionListSnapshot): void;
  fell(code: string): void;
};

export class SessionListSource {
  readonly host: SessionListHost;
  private sid: string | undefined;
  private stop: (() => void) | undefined;

  constructor(
    private readonly hooks: SessionListSourceHooks,
    post: SessionListPost = postNative,
  ) {
    this.host = new SessionListHost(post);
  }

  async open(view: "live" | "all" | "folders" = "all"): Promise<boolean> {
    listenForSessionList();
    const opened: SessionListOpen = await this.host.open(view);
    if ("fallen" in opened) {
      this.hooks.fell(opened.fallen);
      return false;
    }
    this.sid = opened.sid;
    this.stop = this.host.store.subscribe(opened.sid, (snapshot) => this.hooks.changed(snapshot));
    const first = this.host.store.snapshot(opened.sid);
    if (first?.ready) this.hooks.changed(first);
    return true;
  }

  receive(event: SessionListBatch): void {
    this.host.receive(event);
  }

  close(): void {
    this.stop?.();
    this.stop = undefined;
    if (this.sid) this.host.close(this.sid);
    this.sid = undefined;
  }

  dispose(): void {
    this.close();
    removeSessionListHost(this.host);
  }
}
