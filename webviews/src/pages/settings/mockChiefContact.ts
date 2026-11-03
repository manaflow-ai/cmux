// Gallery/test adapter only. It never talks to Messages, a backend or a network.
import type { ChiefContactClient, ChiefContactStatus, LinkErrorCode } from "./chiefContact";

export class MockChiefContact implements ChiefContactClient {
  readonly listeners = new Set<(status: ChiefContactStatus) => void>();
  readonly requests: string[] = [];
  unlinks = 0;
  requestError?: LinkErrorCode;
  holdRequest = false;
  constructor(public value: ChiefContactStatus = { state: "idle" }) {}
  async status() {
    return this.value;
  }
  async request(handle: string): Promise<ChiefContactStatus> {
    this.requests.push(handle);
    if (this.requestError) throw Object.assign(new Error(this.requestError), { code: this.requestError });
    if (this.holdRequest) return new Promise(() => {});
    this.value = { state: "waiting", handle };
    return this.value;
  }
  async unlink() {
    this.unlinks++;
    this.value = { state: "idle" };
    return this.value;
  }
  async subscribe(changed: (status: ChiefContactStatus) => void) {
    this.listeners.add(changed);
    return () => {
      this.listeners.delete(changed);
    };
  }
  publish(value: ChiefContactStatus) {
    this.value = value;
    for (const listener of this.listeners) listener(value);
  }
}
