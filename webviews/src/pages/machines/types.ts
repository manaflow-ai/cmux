// The right sidebar's Machines section (cmux-page://cmux.machines/): its ops, answered by the app's
// MachineSectionPageProvider (CmuxNextServer/AddMachine), which reads the machine registry, each
// machine's last check, the person's hub-joined machines and the section's layout tunable.

export const MachinesOps = {
  /** `{}` → `MachinesSnapshot`. */
  snapshot: "cmux.machines.snapshot",
  /** Stream: the whole `MachinesSnapshot` each time it changes while the section shows (none while
   * it is hidden; the latest one arrives when it shows again). */
  changes: "cmux.machines.changes",
  /** `{machine}` → `{ran}`: New Workspace on a machine (`workspace.newOnMachine`). */
  newWorkspace: "cmux.machines.newWorkspace",
  /** `{}` → `{ran}`: Add Machine… (`device.add`, the Add Device card). */
  addMachine: "cmux.machines.addMachine",
  /** `{row, menu: "row" | "joined", x, y}` → `{}` once the menu closes: the registry's native menu
   * for a row (New Workspace on This Machine) or for a joined machine (Check, Rotate Credential,
   * Revoke…), at the page point (x, y). */
  menu: "cmux.machines.menu",
  /** `{row}` → `{removed}`: Remove a joined machine (asked first on the page). It is revoked if it can
   * still join and leaves every machine list; a false answer leaves the row where it was. */
  remove: "cmux.machines.remove",
} as const;

/** What a machine is: its icon and its group. */
export type MachineKind = "local" | "cloud" | "ssh" | "server" | "joined";

/** What a Cloud machine's server says when it is not simply running. */
export type MachineServerState = "paused" | "resuming" | "failed" | "deleted";

/** The last check's outcome. */
export type HostHealth = "ok" | "warning" | "failing";

/** How the section lays out its machines (`machines.section.style`, Debug Settings > Server). */
export type MachineSectionStyle = "compact" | "grouped" | "flat";

/** A machine that joined through the hub (`cmux machine list`). */
export interface JoinedMachine {
  id: string;
  name: string;
  state: "online" | "offline" | "revoked";
  /** `macos` or `linux`, as reported at redeem. */
  platform?: string;
  /** Who made the line it joined with. */
  mintedBy?: string;
}

/** One machine of the section, as the app reads it (MachineSectionRow). */
export interface MachineRow {
  /** The machine id (`workspace.newOnMachine`'s `machine`); `joined:<id>` for a mesh-only joined row. */
  id: string;
  name: string;
  kind: MachineKind;
  isLocal: boolean;
  isConnected: boolean;
  /** The link is being made, or a resume is on its way (a spinner). Never with a settled serverState. */
  isConnecting: boolean;
  serverState?: MachineServerState;
  health?: HostHealth;
  /** The step the last check flagged (HostStep's raw name). */
  healthStep?: string;
  /** Set for a joined machine (its row has the "…" menu). */
  joined?: JoinedMachine;
}

/** A Revoke, Rotate or Remove on a joined machine. */
export type JoinedMachineChange = "revoke" | "rotate" | "remove";

export interface MachinesSnapshot {
  rows: MachineRow[];
  style: MachineSectionStyle;
  /** Joined machine ids with a Revoke, Rotate or Remove in flight. */
  busy: string[];
  /** The last Revoke, Rotate or Remove that failed, by joined machine id. */
  failed: Record<string, JoinedMachineChange>;
  /** The joined machine whose menu shows as open (the capture fixture's). */
  openMenu?: string;
  /** The team the Cloud machines belong to (the app's active team), named on the Cloud header. */
  cloudTeam?: { name: string; personal: boolean };
}
