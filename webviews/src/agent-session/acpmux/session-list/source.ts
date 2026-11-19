import { postNative } from "../native";
import { listenForSessionList } from "./receiver";
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
  private opening: string | undefined;

  constructor(
    private readonly hooks: SessionListSourceHooks,
    post: SessionListPost = postNative,
  ) {
    this.host = new SessionListHost(post);
  }

  async open(view: "live" | "all" | "folders" = "all"): Promise<boolean> {
    this.close();
    listenForSessionList();
    const opening = `${Date.now()}.${Math.random()}`;
    this.opening = opening;
    const opened: SessionListOpen = await this.host.open(view);
    if (this.opening !== opening) {
      if (!("fallen" in opened)) this.host.close(opened.sid);
      return false;
    }
    this.opening = undefined;
    if ("fallen" in opened) {
      this.hooks.fell(opened.fallen);
      return false;
    }
    this.sid = opened.sid;
    this.stop = this.host.store.subscribe(opened.sid, (snapshot) => this.hooks.changed(snapshot));
    return true;
  }

  receive(event: SessionListBatch): void {
    this.host.receive(event);
  }

  close(): void {
    this.opening = undefined;
    this.stop?.();
    this.stop = undefined;
    if (this.sid) this.host.close(this.sid);
    this.sid = undefined;
  }

  dispose(): void {
    this.close();
    this.host.dispose();
  }
}
