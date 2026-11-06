// The Add Device card's state (plans/cmux-next/add-device-DESIGN.md 2.3), moved from Swift
// (AddDeviceModel, MachineJoinLineModel): which way shows (the pair code first, ssh behind
// Advanced), the network's computers not added yet, the platform of a new device, the footer's
// buttons, and the "Any machine" way's single-use line with its countdown. The card hands off to
// the Add Machine, Add Server and Pair Another Machine cards through the host, so there is still
// one enroll and one approval; this model only decides which one and with what.
//
// The join line's text carries a single-use token: it is shown, never logged, and copied only by
// the host (concealed from clipboard managers), which keeps its own copy of the minted line.

export type AddDeviceWay = "network" | "code" | "newDevice" | "joinLine";
export const ADD_DEVICE_WAYS: readonly AddDeviceWay[] = ["network", "code", "newDevice", "joinLine"];
export type AddDevicePlatform = "macOrLinux" | "windows" | "phone";
export const ADD_DEVICE_PLATFORMS: readonly AddDevicePlatform[] = ["macOrLinux", "windows", "phone"];

/** The line to run on a new computer: install cmux, then show its pairing code and words. */
export function setupLine(platform: AddDevicePlatform): string | null {
  switch (platform) {
    case "macOrLinux":
      return "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux server pair";
    case "windows":
      return "irm https://cmux.com/tui/install-static.ps1 | iex; cmux server pair";
    case "phone":
      return null;
  }
}

/** A computer the network (or ~/.ssh/config) knows that is not a device yet. */
export interface AvailableComputer {
  name: string;
  address: string;
  os: string;
  mine: boolean;
  fromSSHConfig: boolean;
}

export interface DeviceNetwork {
  kind: string;
  up: boolean;
  detail?: string | null;
}

export interface DeviceListingSummary {
  network: DeviceNetwork;
  available: AvailableComputer[];
}

export type Candidates =
  | { state: "loading" }
  | { state: "loaded"; listing: DeviceListingSummary }
  /** The CLI is missing or failed: the network way says so and offers a name instead. */
  | { state: "unavailable" };

export type JoinLineFailure = "signedOut" | "unavailable" | "failed";

/** One minted line. `line` is the secret text; `joinTokenId` is not secret. */
export interface JoinLine {
  line: string;
  joinTokenId: string;
  /** Epoch milliseconds. */
  expiresAt: number;
}

export interface JoinedMachine {
  id: string;
  name: string;
}

export type CheckState = "ok" | "fixed" | "warn" | "fail" | "skip";
export interface JoinCheck {
  step: string;
  state: CheckState;
  detail: string;
  fix?: string | null;
  /** The step's localized title (the host's words). */
  title?: string | null;
}

export type JoinPhase =
  | { phase: "idle" }
  | { phase: "minting" }
  | { phase: "showing"; line: JoinLine }
  | { phase: "joined"; line: JoinLine; machine: JoinedMachine }
  /** The line's time ran out before a machine joined with it. It is never shown again. */
  | { phase: "expired" }
  | { phase: "failed"; failure: JoinLineFailure };

export type AddDeviceAction =
  | { kind: "pick"; computer: AvailableComputer }
  | {
      kind:
        | "otherComputer"
        | "newCloudMachine"
        | "enterCode"
        | "installTailscale"
        | "copyLine"
        | "copyJoinLine"
        | "makeJoinLine"
        | "newJoinLine"
        | "signIn"
        | "showMachines"
        | "pairAnotherMachine"
        | "toggleAdvanced"
        | "done"
        | "cancel";
    };
export type AddDeviceActionKind = AddDeviceAction["kind"];

export interface AddDeviceButton {
  action: Exclude<AddDeviceActionKind, "pick">;
  key: "return" | "escape" | null;
}

/** What the card asks of the app; the page's provider ops (`cmux.addDevice.*`), or fakes in tests. */
export interface AddDeviceServices {
  /** `cmux device list --json`; null when the CLI is missing or failed. */
  list(): Promise<DeviceListingSummary | null>;
  /** Add Machine on `address`, started at once. */
  addComputer(address: string, name: string): void;
  /** Add Machine with an empty field. */
  addByName(): void;
  /** The Add Server card's code field. */
  enterCode(): void;
  /** The app's New Cloud Machine flow (sign-in first when signed out). */
  newCloudMachine(): void;
  installTailscale(): void;
  /** Copies the chosen platform's setup line (plain text: it holds no secret). */
  copySetupLine(platform: AddDevicePlatform): void;
  /** Copies the shown join line, concealed and transient; the host holds the line. */
  copyJoinLine(joinTokenId: string): void;
  showMachines(): void;
  signIn(): void;
  /** Opens the Pair Another Machine card (signed in only). */
  pairAnotherMachine(): void;
  /** `cmux machine add --json --no-wait`: mints a single-use line. */
  mint(name: string | null): Promise<{ line: JoinLine } | { failure: JoinLineFailure }>;
  /** `cmux machine list --json`: the joined row carrying `joinTokenId`, or null. */
  joined(joinTokenId: string): Promise<JoinedMachine | null>;
  /** `cmux machine doctor ID --json`: the joined machine's checks. */
  doctor(id: string): Promise<JoinCheck[]>;
}

/** What the host offers at this opening. */
export interface AddDeviceOffer {
  /** The "Any machine" way (a join service exists). */
  join: boolean;
  /** Signed in: the "Any machine" way hands off to Pair Another Machine. */
  invite: boolean;
}

export interface Clock {
  now(): number;
  /** Runs `fn` once after `ms`; returns a cancel. */
  after(ms: number, fn: () => void): () => void;
}

export const realClock: Clock = {
  now: () => Date.now(),
  after: (ms, fn) => {
    const id = setTimeout(fn, ms);
    return () => clearTimeout(id);
  },
};

export interface AddDeviceState {
  way: AddDeviceWay;
  candidates: Candidates;
  platform: AddDevicePlatform;
  /** The setup line was copied (the button says so until the platform or way changes). */
  copied: boolean;
  offer: AddDeviceOffer;
  join: JoinPhase;
  /** The join line was copied (until a new line). */
  joinCopied: boolean;
  /** The joined machine's checks, after the flip. */
  checks: JoinCheck[];
  /** Now, as of the countdown's last tick. */
  now: number;
}

export class AddDeviceModel {
  private state: AddDeviceState;
  private readonly listeners = new Set<() => void>();
  /** The person picked a way: a late listing never moves them. */
  private chosenByHand = false;
  /** The way before Advanced opened: closing Advanced goes back to it. */
  private beforeAdvanced: AddDeviceWay | null = null;
  private generation = 0;
  private joinGeneration = 0;
  private stopCountdown?: () => void;
  /** The optional name the line is minted with; not state (typing must not redraw). */
  joinName = "";

  /** `initial` sets a state directly (gallery fixtures); the app starts from the defaults. */
  constructor(
    private readonly services: AddDeviceServices,
    private readonly clock: Clock = realClock,
    initial: Partial<AddDeviceState> = {},
  ) {
    this.state = {
      way: "network",
      candidates: { state: "loading" },
      platform: "macOrLinux",
      copied: false,
      offer: { join: false, invite: false },
      join: { phase: "idle" },
      joinCopied: false,
      checks: [],
      now: clock.now(),
      ...initial,
    };
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  getSnapshot = (): AddDeviceState => this.state;

  get way(): AddDeviceWay {
    return this.state.way;
  }

  /** The card opens: back to the default way, the network read again. `way` opens on a way (the
   * `machine.add` and `server.addServer` aliases, a CLI argument). */
  async begin(offer: AddDeviceOffer, way?: AddDeviceWay | null): Promise<void> {
    const mine = ++this.generation;
    this.closeJoin();
    const offered: AddDeviceOffer = { join: offer.join, invite: offer.join && offer.invite };
    const ways = allWays(offered);
    const start = way && ways.includes(way) ? way : defaultWay(offered);
    this.chosenByHand = start === way;
    this.beforeAdvanced = null;
    this.set({ offer: offered, way: start, copied: false, candidates: { state: "loading" } });
    const listing = await this.services.list();
    if (mine !== this.generation) return;
    this.set({ candidates: listing ? { state: "loaded", listing } : { state: "unavailable" } });
    // Only the ssh-first card moves to setup when the network has nothing to add; the pair code
    // works whatever the network lists.
    if (!this.chosenByHand && this.state.way === "network" && this.available.length === 0) {
      this.set({ way: "newDevice" });
    }
  }

  get ways(): AddDeviceWay[] {
    return switchWays(this.state.offer);
  }

  get advancedWays(): AddDeviceWay[] {
    return advancedWays(this.state.offer);
  }

  get showsAdvanced(): boolean {
    return this.advancedWays.includes(this.state.way);
  }

  get available(): AvailableComputer[] {
    const c = this.state.candidates;
    return c.state === "loaded" ? c.listing.available : [];
  }

  /** Why the network is not up, for the network way; ~/.ssh/config computers still list under it. */
  get networkProblem(): string | null {
    const c = this.state.candidates;
    if (c.state !== "loaded" || c.listing.network.up) return null;
    return c.listing.network.detail ?? null;
  }

  get canInstallTailscale(): boolean {
    const c = this.state.candidates;
    return c.state === "loaded" && c.listing.network.kind === "none" && !c.listing.network.up;
  }

  /** "Set up a new device" for a computer also offers Other Computer… (add by host name). */
  get offersOtherComputer(): boolean {
    return this.state.way === "newDevice" && setupLine(this.state.platform) !== null;
  }

  /** The shown line, while it still works. */
  get joinLine(): JoinLine | null {
    const j = this.state.join;
    return j.phase === "showing" ? j.line : null;
  }

  /** Seconds left on the shown line, rounded up; null when no line shows. */
  get secondsLeft(): number | null {
    const line = this.joinLine;
    if (!line) return null;
    return Math.max(0, Math.ceil((line.expiresAt - this.state.now) / 1000));
  }

  /** Whether the countdown still runs (tests check that close stops it). */
  get isWatching(): boolean {
    return this.stopCountdown !== undefined;
  }

  chooseWay(way: AddDeviceWay): void {
    const all = allWays(this.state.offer);
    if (!all.includes(way)) return;
    this.chosenByHand = true;
    if (this.advancedWays.includes(way) && !this.showsAdvanced) this.beforeAdvanced = this.state.way;
    this.set({ way, copied: false });
  }

  choosePlatform(platform: AddDevicePlatform): void {
    this.set({ platform, copied: false });
  }

  /** Opening Advanced shows ssh; closing it goes back to the way the card was on. */
  toggleAdvanced(): void {
    const advanced = this.advancedWays[0];
    if (!advanced) return;
    if (this.showsAdvanced) {
      const back = this.beforeAdvanced && this.ways.includes(this.beforeAdvanced) ? this.beforeAdvanced : null;
      this.chooseWay(back ?? defaultWay(this.state.offer));
    } else {
      this.chooseWay(advanced);
    }
  }

  /** The footer for the current way: an Escape button, and a Return button where one fits. */
  get buttons(): AddDeviceButton[] {
    const cancel: AddDeviceButton = { action: "cancel", key: "escape" };
    switch (this.state.way) {
      case "network":
        return [cancel, { action: "newCloudMachine", key: null }, { action: "otherComputer", key: null }];
      case "code":
        return [cancel, { action: "enterCode", key: "return" }];
      case "newDevice":
        if (this.state.platform === "phone") return [{ action: "done", key: "return" }];
        return [cancel, { action: "newCloudMachine", key: null }, { action: "copyLine", key: "return" }];
      case "joinLine":
        return this.joinLineButtons(cancel);
    }
  }

  private joinLineButtons(cancel: AddDeviceButton): AddDeviceButton[] {
    if (this.state.offer.invite) return [cancel, { action: "pairAnotherMachine", key: "return" }];
    const j = this.state.join;
    switch (j.phase) {
      case "showing":
        return [cancel, { action: "copyJoinLine", key: "return" }];
      case "joined":
        return [
          { action: "showMachines", key: null },
          { action: "done", key: "return" },
        ];
      case "failed":
        // Signed out, a new line would be refused again: Sign In instead.
        return j.failure === "signedOut"
          ? [cancel, { action: "signIn", key: "return" }]
          : [cancel, { action: "newJoinLine", key: "return" }];
      case "expired":
        return [cancel, { action: "newJoinLine", key: "return" }];
      case "idle":
        return [cancel, { action: "makeJoinLine", key: "return" }];
      case "minting":
        return [cancel];
    }
  }

  /** Runs a control (its click or its key). Returns true when the card should close. */
  perform(action: AddDeviceAction): boolean {
    switch (action.kind) {
      case "pick":
        this.services.addComputer(action.computer.address, action.computer.name);
        return this.closing();
      case "otherComputer":
        this.services.addByName();
        return this.closing();
      case "newCloudMachine":
        this.services.newCloudMachine();
        return this.closing();
      case "enterCode":
        this.services.enterCode();
        return this.closing();
      case "installTailscale":
        if (this.canInstallTailscale) this.services.installTailscale();
        return false;
      case "copyLine": {
        if (setupLine(this.state.platform) === null) return false;
        this.services.copySetupLine(this.state.platform);
        this.set({ copied: true });
        return false;
      }
      case "copyJoinLine": {
        const line = this.joinLine;
        if (!line) return false;
        this.services.copyJoinLine(line.joinTokenId);
        this.set({ joinCopied: true });
        return false;
      }
      case "makeJoinLine":
      case "newJoinLine":
        if (this.state.offer.join) void this.mint();
        return false;
      case "signIn":
        this.services.signIn();
        return this.closing();
      case "showMachines":
        this.services.showMachines();
        return this.closing();
      case "toggleAdvanced":
        this.toggleAdvanced();
        return false;
      case "pairAnotherMachine":
        if (!this.state.offer.invite) return false;
        this.closeCard();
        this.services.pairAnotherMachine();
        return true;
      case "done":
      case "cancel":
        return this.closing();
    }
  }

  private closing(): true {
    this.closeCard();
    return true;
  }

  /** The card closes: a late listing or mint is dropped, and the countdown stops. */
  closeCard(): void {
    this.generation++;
    this.closeJoin();
  }

  /** Mints a new line (Make Line, New Line). A line is never shown twice. */
  async mint(): Promise<void> {
    this.stop();
    const mine = ++this.joinGeneration;
    this.set({ joinCopied: false, checks: [], join: { phase: "minting" } });
    const trimmed = this.joinName.trim();
    const result = await this.services.mint(trimmed === "" ? null : trimmed);
    if (mine !== this.joinGeneration) return;
    if ("failure" in result) {
      this.set({ join: { phase: "failed", failure: result.failure } });
      return;
    }
    const now = this.clock.now();
    if (result.line.expiresAt <= now) {
      this.set({ now, join: { phase: "expired" } });
      return;
    }
    this.set({ now, join: { phase: "showing", line: result.line } });
    this.startCountdown(mine);
    await this.refresh();
  }

  /** Reads the machine list once and flips to joined when a row carries the shown line's
   * `joinTokenId`. The card's focus and each mesh change call it; nothing polls. */
  async refresh(): Promise<void> {
    const line = this.joinLine;
    if (!line) return;
    const mine = this.joinGeneration;
    const machine = await this.services.joined(line.joinTokenId);
    if (mine !== this.joinGeneration || this.state.join.phase !== "showing" || !machine) return;
    this.stop();
    this.set({ join: { phase: "joined", line, machine } });
    const checks = await this.services.doctor(machine.id);
    if (mine !== this.joinGeneration) return;
    this.set({ checks });
  }

  /** The countdown's tick: moves `now`, and ends the line at `expiresAt`. */
  tick(): void {
    const now = this.clock.now();
    const line = this.joinLine;
    if (line && line.expiresAt <= now) {
      this.stop();
      this.set({ now, join: { phase: "expired" } });
      return;
    }
    this.set({ now });
  }

  private closeJoin(): void {
    this.joinGeneration++;
    this.stop();
    this.set({ join: { phase: "idle" }, joinCopied: false, checks: [] });
  }

  private stop(): void {
    this.stopCountdown?.();
    this.stopCountdown = undefined;
  }

  /** One tick per second while a line shows; ends at expiry, on the flip, on close and on a new
   * mint. Each tick is a visible change ("Expires in 9:41"), never an idle wakeup. */
  private startCountdown(mine: number): void {
    const step = () => {
      this.stopCountdown = this.clock.after(1000, () => {
        if (mine !== this.joinGeneration || this.stopCountdown === undefined) return;
        this.tick();
        if (this.state.join.phase === "showing") step();
      });
    };
    step();
  }

  private set(patch: Partial<AddDeviceState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** The way the card opens on: the pair code (no ssh) when offered, else the network. */
export function defaultWay(offer: AddDeviceOffer): AddDeviceWay {
  return offer.join ? "joinLine" : "network";
}

/** The switch's ways. With the join offered: "Any machine" first, ssh behind Advanced. */
export function switchWays(offer: AddDeviceOffer): AddDeviceWay[] {
  return offer.join ? ["joinLine", "code", "newDevice"] : ["network", "code", "newDevice"];
}

export function advancedWays(offer: AddDeviceOffer): AddDeviceWay[] {
  return offer.join ? ["network"] : [];
}

export function allWays(offer: AddDeviceOffer): AddDeviceWay[] {
  return [...switchWays(offer), ...advancedWays(offer)];
}

export function isWay(value: unknown): value is AddDeviceWay {
  return typeof value === "string" && (ADD_DEVICE_WAYS as readonly string[]).includes(value);
}

/** "9:41" from seconds. */
export function clockText(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
