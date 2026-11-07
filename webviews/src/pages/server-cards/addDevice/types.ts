// Add Device (`#/add-device`): the ops the app answers (AddDeviceCardProvider.swift). Swift keeps
// the CLI runs (`cmux device list`, `cmux machine add|list|doctor`), the clipboard, and the
// hand-offs to the Add Machine, Add Server and Pair Another Machine cards; the page derives the
// way, the buttons, the join line's phases and its countdown (model.ts).

export const AddDeviceOps = {
  /** `{}` → `AddDeviceStatus`. */
  status: "cmux.addDevice.status",
  /** `{}` → `DeviceListingSummary | null` (`cmux device list --json`; null: the CLI failed). */
  list: "cmux.addDevice.list",
  /** `{address, name}` → null: Add Machine on that computer, started at once. The person's own click or key. */
  addComputer: "cmux.addDevice.addComputer",
  /** `{}` → null: Add Machine with an empty field. The person's own click or key. */
  addByName: "cmux.addDevice.addByName",
  /** `{}` → null: Add Server's code field. The person's own click or key. */
  enterCode: "cmux.addDevice.enterCode",
  /** `{}` → null: the app's New Cloud Machine. The person's own click or key. */
  newCloudMachine: "cmux.addDevice.newCloudMachine",
  /** `{}` → null: Tailscale's download page. The person's own click or key. */
  installTailscale: "cmux.addDevice.installTailscale",
  /** `{platform}` → null: copies that platform's setup line. The person's own click or key. */
  copySetupLine: "cmux.addDevice.copySetupLine",
  /** `{}` → null: copies the shown join line, concealed and transient. The person's own click or key. */
  copyJoinLine: "cmux.addDevice.copyJoinLine",
  /** `{}` → null: the app's Sign In. The person's own click or key. */
  signIn: "cmux.addDevice.signIn",
  /** `{}` → null: the Machines sidebar section. The person's own click or key. */
  showMachines: "cmux.addDevice.showMachines",
  /** `{}` → null: the Pair Another Machine card (signed in). The person's own click or key. */
  pairAnotherMachine: "cmux.addDevice.pairAnotherMachine",
  /** `{name}` → `{line}` or `{failure}`: mints a single-use join line. The person's own click or key. */
  mint: "cmux.addDevice.mint",
  /** `{}` → `JoinedMachine | null`: the machine that joined with the shown line, read once. */
  joined: "cmux.addDevice.joined",
  /** `{}` → `JoinCheck[]`: the joined machine's checks. */
  doctor: "cmux.addDevice.doctor",
  /** Stream: `{kind: "opened" | "closed"}` (the panel opened or closed the card; read `status`)
   * and `{kind: "mesh"}` (a machine connected or left while a line shows; read `joined`). */
  changes: "cmux.addDevice.changes",
} as const;

export const ADD_DEVICE_CARD = "add-device";

export interface AddDeviceStatus {
  /** One per opening; a new one starts the card over. */
  session: number;
  /** The panel shows the card. */
  open: boolean;
  /** The way the opening asked for (`device.add way=…`), or null. */
  way: string | null;
  /** The "Any machine" way is offered (a join service exists). */
  join: boolean;
  /** Signed in: the "Any machine" way hands off to Pair Another Machine. */
  invite: boolean;
  /** Debug captures only: Make Line pressed with this name once the card opened. */
  mintName?: string;
}

export interface AddDeviceChange {
  kind?: "opened" | "closed" | "mesh";
}
