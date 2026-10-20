// The Mobile Pairing page's state owner. Stub: implemented in the next commit.
import type { PageClient } from "../shared/pageClient";
import type { MobilePairingStatus } from "./types";

export interface MobilePairingSnapshot {
  status?: MobilePairingStatus;
  loading: boolean;
  failed?: { message?: string };
  unavailable?: boolean;
}

export class MobilePairingStore {
  private snapshot: MobilePairingSnapshot = { loading: true };

  constructor(
    private readonly client: PageClient | null,
    private readonly now: () => number = Date.now,
  ) {}

  subscribe = (_listener: () => void) => () => {};
  getSnapshot = () => this.snapshot;

  async start(): Promise<void> {
    void this.client;
    void this.now;
  }
  stop(): void {}
  async refresh(): Promise<void> {}
  async refreshIfExpired(): Promise<void> {}
  async setAllowed(_on: boolean): Promise<void> {}
  async signIn(): Promise<void> {}
  async openAccounts(): Promise<void> {}
}
