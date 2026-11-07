// The Add Device card's state owner on the page: the model (model.ts) over the host's ops. Each
// opening (a new `session`) starts the model over on the way it asked for; a close drops a late
// read and stops the countdown; a mesh change or the panel's focus reads the machine list once
// while a join line shows. Nothing here polls.
import type { PageClient } from "../../shared/pageClient";
import {
  AddDeviceModel,
  isWay,
  realClock,
  type AddDeviceServices,
  type Clock,
  type DeviceListingSummary,
  type JoinCheck,
  type JoinedMachine,
  type JoinLine,
  type JoinLineFailure,
} from "./model";
import { AddDeviceOps, type AddDeviceChange, type AddDeviceStatus } from "./types";

/** The host's ops as the model's services. An action the host refuses changes nothing here. */
export function clientServices(client: PageClient | null): AddDeviceServices {
  const run = (op: string, params: unknown = {}) => void client?.call(op, params).catch(() => {});
  return {
    list: async () => {
      if (!client) return null;
      try {
        return await client.call<DeviceListingSummary | null>(AddDeviceOps.list, {});
      } catch {
        return null;
      }
    },
    addComputer: (address, name) => run(AddDeviceOps.addComputer, { address, name }),
    addByName: () => run(AddDeviceOps.addByName),
    enterCode: () => run(AddDeviceOps.enterCode),
    newCloudMachine: () => run(AddDeviceOps.newCloudMachine),
    installTailscale: () => run(AddDeviceOps.installTailscale),
    copySetupLine: (platform) => run(AddDeviceOps.copySetupLine, { platform }),
    // The host holds the minted line: the page never sends the secret back.
    copyJoinLine: () => run(AddDeviceOps.copyJoinLine),
    showMachines: () => run(AddDeviceOps.showMachines),
    signIn: () => run(AddDeviceOps.signIn),
    pairAnotherMachine: () => run(AddDeviceOps.pairAnotherMachine),
    mint: async (name) => {
      if (!client) return { failure: "failed" };
      try {
        const reply = await client.call<{ line?: JoinLine; failure?: JoinLineFailure }>(AddDeviceOps.mint, { name });
        if (reply?.line) return { line: reply.line };
        return { failure: reply?.failure ?? "failed" };
      } catch {
        return { failure: "failed" };
      }
    },
    joined: async () => {
      if (!client) return null;
      try {
        return await client.call<JoinedMachine | null>(AddDeviceOps.joined, {});
      } catch {
        return null;
      }
    },
    doctor: async () => {
      if (!client) return [];
      try {
        return (await client.call<JoinCheck[] | null>(AddDeviceOps.doctor, {})) ?? [];
      } catch {
        return [];
      }
    },
  };
}

export class AddDeviceStore {
  readonly model: AddDeviceModel;
  private session: number | null = null;
  private request = 0;
  private stopChanges?: () => void;
  private stopped = false;

  constructor(
    private readonly client: PageClient | null,
    clock: Clock = realClock,
  ) {
    this.model = new AddDeviceModel(clientServices(client), clock);
  }

  /** Follows the host's change events, then reads the status once. */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const stop = await this.client.subscribe<AddDeviceChange>(AddDeviceOps.changes, (change) => {
        if (change?.kind === "mesh") void this.model.refresh();
        else void this.refresh();
      });
      if (this.stopped) stop();
      else this.stopChanges = stop;
    } catch {
      // Without change events the card still reads on open.
    }
    await this.refresh();
  }

  stop(): void {
    this.stopped = true;
    this.stopChanges?.();
    this.stopChanges = undefined;
    this.model.closeCard();
  }

  /** The panel got the focus (the person came back from the new machine's terminal): one read. */
  focused(): void {
    void this.model.refresh();
  }

  async refresh(): Promise<void> {
    if (!this.client) return;
    const id = ++this.request;
    let status: AddDeviceStatus;
    try {
      status = await this.client.call<AddDeviceStatus>(AddDeviceOps.status, {});
    } catch {
      return;
    }
    if (id !== this.request) return;
    await this.apply(status);
  }

  /** A new opening starts the card over; a close stops it. */
  async apply(status: AddDeviceStatus): Promise<void> {
    if (!status.open) {
      this.session = null;
      this.model.closeCard();
      return;
    }
    if (status.session === this.session) return;
    this.session = status.session;
    await this.model.begin({ join: status.join, invite: status.invite }, isWay(status.way) ? status.way : null);
    // Debug captures: the card's Make Line, pressed for the capture.
    if (status.mintName !== undefined && this.session === status.session && status.join) {
      this.model.joinName = status.mintName;
      await this.model.mint();
    }
  }
}
