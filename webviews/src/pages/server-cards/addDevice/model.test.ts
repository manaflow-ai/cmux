// Add Device's state, ported from the Swift suites AddDeviceFlowTests, MachineJoinLineFlowTests,
// AddDeviceSignInTests and PairInviteFlowTests' Add Device cases: the way the card opens on, the
// hand-offs (Add Machine, Add Server, New Cloud VM, Pair Another Machine), the copies (the setup
// line plain, the join line concealed through the host only), a late listing never moving a person
// who chose a way, Advanced over ssh, and the "Any machine" line: minted only on Make Line, joined
// when a listed machine carries its `joinTokenId`, expired at `expiresAt`, read on a trigger and
// never on a timer, and the countdown stopped on close, on the flip and at expiry.
import { describe, expect, test } from "bun:test";
import {
  AddDeviceModel,
  clockText,
  setupLine,
  type AddDeviceOffer,
  type AddDeviceServices,
  type Clock,
  type DeviceListingSummary,
  type JoinCheck,
  type JoinedMachine,
  type JoinLine,
  type JoinLineFailure,
} from "./model";

function listing(available: DeviceListingSummary["available"], up = true): DeviceListingSummary {
  return {
    network: { kind: up ? "tailscale" : "none", up, detail: up ? null : "Tailscale is not installed on this machine." },
    available,
  };
}
const studio = { name: "studio", address: "studio.tail1234.ts.net", os: "macOS", mine: true, fromSSHConfig: false };

class FakeClock implements Clock {
  t = 1_000_000_000;
  timers: { at: number; fn: () => void; live: boolean }[] = [];
  now = () => this.t;
  after = (ms: number, fn: () => void) => {
    const timer = { at: this.t + ms, fn, live: true };
    this.timers.push(timer);
    return () => void (timer.live = false);
  };
  get live() {
    return this.timers.filter((t) => t.live).length;
  }
  /** Moves time by `ms`, firing each due timer once. */
  advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      const due = this.timers.filter((t) => t.live && t.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      due.live = false;
      this.t = due.at;
      due.fn();
    }
    this.t = end;
  }
}

class Fake {
  listing: DeviceListingSummary | null = listing([studio]);
  hold?: () => void;
  holdNext = false;
  added: [string, string][] = [];
  byName = 0;
  codes = 0;
  clouds = 0;
  installs = 0;
  copied: string[] = [];
  concealed: string[] = [];
  signIns = 0;
  machinesShown = 0;
  invites = 0;
  mints: (string | null)[] = [];
  lists = 0;
  doctors: string[] = [];
  rows: (JoinedMachine & { joinTokenId: string })[] = [];
  mintResult: { line: JoinLine } | { failure: JoinLineFailure } | null = null;
  readonly clock = new FakeClock();
  line: JoinLine = {
    line: " curl -fsSL https://cmux.example/v1/machines/join.sh | CMUX_JOIN=cmj_TESTTOKEN sh",
    joinTokenId: "jt_1",
    expiresAt: this.clock.t + 600_000,
  };

  services(): AddDeviceServices {
    return {
      list: async () => {
        if (this.holdNext) {
          this.holdNext = false;
          await new Promise<void>((resolve) => (this.hold = resolve));
        }
        return this.listing;
      },
      addComputer: (address, name) => void this.added.push([address, name]),
      addByName: () => void this.byName++,
      enterCode: () => void this.codes++,
      newCloudMachine: () => void this.clouds++,
      installTailscale: () => void this.installs++,
      copySetupLine: (platform) => void this.copied.push(setupLine(platform)!),
      copyJoinLine: (id) => void this.concealed.push(id),
      showMachines: () => void this.machinesShown++,
      signIn: () => void this.signIns++,
      pairAnotherMachine: () => void this.invites++,
      mint: async (name) => {
        this.mints.push(name);
        return this.mintResult ?? { line: this.line };
      },
      joined: async (id) => {
        this.lists++;
        return this.rows.find((r) => r.joinTokenId === id) ?? null;
      },
      doctor: async (id): Promise<JoinCheck[]> => {
        this.doctors.push(id);
        return [{ step: "heartbeat", state: "ok", detail: "" }];
      },
    };
  }

  model() {
    return new AddDeviceModel(this.services(), this.clock);
  }
}

const sshFirst: AddDeviceOffer = { join: false, invite: false };
const joinOffer: AddDeviceOffer = { join: true, invite: false };
const actions = (m: AddDeviceModel) => m.buttons.map((b) => b.action);

describe("the ssh-first card (no join offered)", () => {
  test("opens on the network way when the network lists a computer", async () => {
    const m = new Fake().model();
    await m.begin(sshFirst);
    expect(m.way).toBe("network");
    expect(m.available.map((c) => c.name)).toEqual(["studio"]);
    expect(actions(m)).toEqual(["cancel", "newCloudMachine", "otherComputer"]);
  });

  test("New Cloud VM… runs the create flow and closes", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(sshFirst);
    expect(m.perform({ kind: "newCloudMachine" })).toBe(true);
    expect(fake.clouds).toBe(1);
  });

  test("~/.ssh/config computers list without the network", async () => {
    const fake = new Fake();
    fake.listing = listing([{ name: "devbox", address: "devbox", os: "", mine: true, fromSSHConfig: true }], false);
    const m = fake.model();
    await m.begin(sshFirst);
    expect(m.way).toBe("network");
    expect(m.networkProblem).not.toBeNull();
    expect(m.perform({ kind: "pick", computer: m.available[0]! })).toBe(true);
    expect(fake.added.map((a) => a[0])).toEqual(["devbox"]);
  });

  test("opens on Set up a new device when nothing is left to add", async () => {
    const fake = new Fake();
    fake.listing = listing([]);
    const m = fake.model();
    await m.begin(sshFirst);
    expect(m.way).toBe("newDevice");
    expect(actions(m)).toEqual(["cancel", "newCloudMachine", "copyLine"]);
    expect(m.buttons.at(-1)?.key).toBe("return");
    expect(m.perform({ kind: "newCloudMachine" })).toBe(true);
    expect(fake.clouds).toBe(1);
  });

  test("Set up a new device still offers Other Computer… for a computer, not a phone", async () => {
    const fake = new Fake();
    fake.listing = listing([]);
    const m = fake.model();
    await m.begin(sshFirst);
    expect(m.offersOtherComputer).toBe(true);
    expect(m.perform({ kind: "otherComputer" })).toBe(true);
    expect(fake.byName).toBe(1);
    m.choosePlatform("windows");
    expect(m.offersOtherComputer).toBe(true);
    m.choosePlatform("phone");
    expect(m.offersOtherComputer).toBe(false);
    m.chooseWay("code");
    expect(m.offersOtherComputer).toBe(false);
  });

  test("no CLI shows the network as unavailable and still offers a name", async () => {
    const fake = new Fake();
    fake.listing = null;
    const m = fake.model();
    await m.begin(sshFirst, "network");
    expect(m.getSnapshot().candidates).toEqual({ state: "unavailable" });
    expect(m.perform({ kind: "otherComputer" })).toBe(true);
    expect(fake.byName).toBe(1);
  });

  test("a network that is down says why", async () => {
    const fake = new Fake();
    fake.listing = listing([], false);
    const m = fake.model();
    await m.begin(sshFirst, "network");
    expect(m.networkProblem).toBe("Tailscale is not installed on this machine.");
  });

  test("missing Tailscale offers an explicit install that keeps the card open", async () => {
    const fake = new Fake();
    fake.listing = listing([], false);
    const m = fake.model();
    await m.begin(sshFirst, "network");
    expect(m.canInstallTailscale).toBe(true);
    expect(m.perform({ kind: "installTailscale" })).toBe(false);
    expect(fake.installs).toBe(1);
    fake.listing = listing([]);
    await m.begin(sshFirst, "network");
    expect(m.canInstallTailscale).toBe(false);
    expect(m.perform({ kind: "installTailscale" })).toBe(false);
    expect(fake.installs).toBe(1);
  });

  test("picking a computer hands it to Add Machine and closes", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(sshFirst);
    expect(m.perform({ kind: "pick", computer: m.available[0]! })).toBe(true);
    expect(fake.added).toEqual([["studio.tail1234.ts.net", "studio"]]);
  });

  test("Enter Code opens Add Server; Copy Line copies the platform's line", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(sshFirst, "code");
    expect(actions(m)).toEqual(["cancel", "enterCode"]);
    expect(m.perform({ kind: "enterCode" })).toBe(true);
    expect(fake.codes).toBe(1);
    m.chooseWay("newDevice");
    m.choosePlatform("windows");
    expect(m.perform({ kind: "copyLine" })).toBe(false);
    expect(fake.copied).toEqual([setupLine("windows")!]);
    expect(m.getSnapshot().copied).toBe(true);
    m.choosePlatform("phone");
    expect(m.getSnapshot().copied).toBe(false);
    expect(actions(m)).toEqual(["done"]);
  });

  test("a late listing never moves a person who chose a way", async () => {
    const fake = new Fake();
    fake.listing = listing([]);
    fake.holdNext = true;
    const m = fake.model();
    const begin = m.begin(sshFirst);
    while (!fake.hold) await Promise.resolve();
    m.chooseWay("code");
    fake.hold();
    await begin;
    expect(m.way).toBe("code");
  });

  test("the setup lines install cmux and show a pairing code", () => {
    expect(setupLine("macOrLinux")?.startsWith("curl -fsSL https://cmux.com/tui/install-static.sh | sh")).toBe(true);
    expect(setupLine("macOrLinux")?.endsWith("cmux server pair")).toBe(true);
    expect(setupLine("windows")).toContain("install-static.ps1");
    expect(setupLine("phone")).toBeNull();
  });

  test("the join way is hidden when the app offers no join", async () => {
    const m = new Fake().model();
    await m.begin(sshFirst, "joinLine");
    expect(m.ways).not.toContain("joinLine");
    expect(m.advancedWays).toEqual([]);
    expect(m.way).toBe("network");
    m.chooseWay("joinLine");
    expect(m.way).toBe("network");
  });

  test("an invite offered without a join adds no way", async () => {
    const m = new Fake().model();
    await m.begin({ join: false, invite: true });
    expect(m.getSnapshot().offer.invite).toBe(false);
    expect(m.ways).toEqual(["network", "code", "newDevice"]);
  });
});

describe("the Any machine way", () => {
  test("is the default and mints only on Make Line", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    expect(m.ways).toEqual(["joinLine", "code", "newDevice"]);
    expect(m.advancedWays).toEqual(["network"]);
    expect(m.way).toBe("joinLine");
    expect(m.showsAdvanced).toBe(false);
    expect(m.getSnapshot().join.phase).toBe("idle");
    expect(fake.mints).toEqual([]);
    expect(actions(m)).toEqual(["cancel", "makeJoinLine"]);
    m.joinName = "  lane-vm-3 ";
    await m.mint();
    expect(fake.mints).toEqual(["lane-vm-3"]);
    expect(m.joinLine).toEqual(fake.line);
    expect(actions(m)).toEqual(["cancel", "copyJoinLine"]);
  });

  test("Copy Line copies through the host's concealed copy only", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    expect(m.perform({ kind: "copyJoinLine" })).toBe(false);
    expect(fake.concealed).toEqual(["jt_1"]);
    expect(fake.copied).toEqual([]);
    expect(m.getSnapshot().joinCopied).toBe(true);
  });

  test("flips to joined when the list carries its joinTokenId", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    expect(fake.lists).toBe(1);
    fake.rows = [{ id: "m_else", name: "someone-else", joinTokenId: "jt_other" }];
    await m.refresh();
    expect(m.getSnapshot().join.phase).toBe("showing");
    fake.rows.push({ id: "m_lane-vm-3", name: "lane-vm-3", joinTokenId: "jt_1" });
    await m.refresh();
    const j = m.getSnapshot().join;
    expect(j.phase).toBe("joined");
    expect(j.phase === "joined" && j.machine.name).toBe("lane-vm-3");
    expect(fake.doctors).toEqual(["m_lane-vm-3"]);
    expect(m.getSnapshot().checks.map((c) => c.step)).toEqual(["heartbeat"]);
    expect(m.isWatching).toBe(false);
    expect(actions(m)).toEqual(["showMachines", "done"]);
  });

  test("nothing but a trigger reads the list", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    fake.clock.advance(30_000);
    expect(fake.lists).toBe(1);
    expect(fake.clock.live).toBe(1);
  });

  test("expires at expiresAt and never shows the line again", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    fake.clock.advance(599_200);
    expect(m.secondsLeft).toBe(1);
    fake.clock.advance(1_000);
    expect(m.getSnapshot().join.phase).toBe("expired");
    expect(m.joinLine).toBeNull();
    expect(m.isWatching).toBe(false);
    expect(fake.clock.live).toBe(0);
    expect(actions(m)).toEqual(["cancel", "newJoinLine"]);
    fake.line = { line: " curl … | CMUX_JOIN=cmj_SECOND sh", joinTokenId: "jt_2", expiresAt: fake.clock.t + 600_000 };
    await m.mint();
    expect(m.joinLine?.joinTokenId).toBe("jt_2");
  });

  test("a line minted already expired is never shown", async () => {
    const fake = new Fake();
    fake.line = { ...fake.line, expiresAt: fake.clock.t - 1 };
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    expect(m.getSnapshot().join.phase).toBe("expired");
  });

  test("close stops the countdown and drops a later read", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    await m.mint();
    expect(m.isWatching).toBe(true);
    expect(m.perform({ kind: "cancel" })).toBe(true);
    expect(m.isWatching).toBe(false);
    expect(fake.clock.live).toBe(0);
    expect(m.getSnapshot().join.phase).toBe("idle");
    const lists = fake.lists;
    await m.refresh();
    expect(fake.lists).toBe(lists);
  });

  test("a failed mint says why; signed out offers Sign In, which closes the card", async () => {
    const fake = new Fake();
    fake.mintResult = { failure: "signedOut" };
    const m = fake.model();
    await m.begin(joinOffer, "joinLine");
    await m.mint();
    expect(m.getSnapshot().join).toEqual({ phase: "failed", failure: "signedOut" });
    expect(m.buttons).toEqual([
      { action: "cancel", key: "escape" },
      { action: "signIn", key: "return" },
    ]);
    expect(m.isWatching).toBe(false);
    expect(m.perform({ kind: "signIn" })).toBe(true);
    expect(fake.signIns).toBe(1);
  });

  test("another failure still offers New Line", async () => {
    const fake = new Fake();
    fake.mintResult = { failure: "failed" };
    const m = fake.model();
    await m.begin(joinOffer, "joinLine");
    await m.mint();
    expect(actions(m)).toEqual(["cancel", "newJoinLine"]);
  });

  test("Advanced opens the ssh way, which still adds; closing goes back", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    m.chooseWay("code");
    expect(m.perform({ kind: "toggleAdvanced" })).toBe(false);
    expect(m.way).toBe("network");
    expect(m.showsAdvanced).toBe(true);
    expect(m.available.map((c) => c.name)).toEqual(["studio"]);
    expect(actions(m)).toEqual(["cancel", "newCloudMachine", "otherComputer"]);
    m.perform({ kind: "toggleAdvanced" });
    expect(m.way).toBe("code");
    m.perform({ kind: "toggleAdvanced" });
    expect(m.perform({ kind: "pick", computer: m.available[0]! })).toBe(true);
    expect(fake.added.map((a) => a[0])).toEqual(["studio.tail1234.ts.net"]);
  });

  test("asking for the ssh way opens it under Advanced", async () => {
    const m = new Fake().model();
    await m.begin(joinOffer, "network");
    expect(m.way).toBe("network");
    expect(m.showsAdvanced).toBe(true);
    m.toggleAdvanced();
    expect(m.way).toBe("joinLine");
  });

  test("signed in, the way hands off to Pair Another Machine", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin({ join: true, invite: true }, "joinLine");
    expect(actions(m)).toEqual(["cancel", "pairAnotherMachine"]);
    expect(m.perform({ kind: "pairAnotherMachine" })).toBe(true);
    expect(fake.invites).toBe(1);
  });

  test("signed out, the way keeps the ticket line", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer, "joinLine");
    expect(actions(m)).toEqual(["cancel", "makeJoinLine"]);
    expect(m.perform({ kind: "pairAnotherMachine" })).toBe(false);
    expect(fake.invites).toBe(0);
  });

  test("a reopening drops a late mint of the last opening", async () => {
    const fake = new Fake();
    let release!: () => void;
    const services = fake.services();
    services.mint = () => new Promise((resolve) => (release = () => resolve({ line: fake.line })));
    const m = new AddDeviceModel(services, fake.clock);
    await m.begin(joinOffer);
    const minting = m.mint();
    await m.begin(joinOffer);
    release();
    await minting;
    expect(m.getSnapshot().join.phase).toBe("idle");
    expect(fake.clock.live).toBe(0);
  });

  test("the countdown reads as minutes and seconds", () => {
    expect(clockText(581)).toBe("9:41");
    expect(clockText(40)).toBe("0:40");
  });

  test("a new opening forgets the last name", async () => {
    const fake = new Fake();
    const m = fake.model();
    await m.begin(joinOffer);
    const first = m.getSnapshot().opening;
    m.joinName = "old-box";
    await m.begin(joinOffer);
    expect(m.joinName).toBe("");
    expect(m.getSnapshot().opening).toBe(first + 1);
    await m.mint();
    expect(fake.mints).toEqual([null]);
  });
});
