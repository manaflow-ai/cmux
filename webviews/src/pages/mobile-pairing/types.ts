// The Mobile Pairing page's ops (cmux-page://cmux.mobile-pairing/, palette "Open Mobile Pairing"):
// the app answers them from its phone host (CmuxNextPhoneAccess, plans/cmux-next/cloud-ios.md).

export const MobilePairingOps = {
  /** `{}` → `MobilePairingStatus`. */
  status: "cmux.mobilePairing.status",
  /** `{on}` → `{}`: Settings > Accounts > Phone Access. Only after the person's own click. */
  setAllowed: "cmux.mobilePairing.setAllowed",
  /** Stream: one empty event whenever the status may have changed; the page asks again. */
  changes: "cmux.mobilePairing.changes",
} as const;

/** The host's native op that runs one of the page's registry actions. */
export const ACTION_RUN = "cmux.app.action.run";

/** The actions the page may run (`PageDescriptor.mobilePairing.actions`). */
export const PairingActions = {
  signIn: "palette.auth.signIn",
  accounts: "accounts.show",
} as const;

/** The one step between this Mac and a phone, in order: account, phone access, listener. */
export type PairingState = "signedOut" | "accessOff" | "preparing" | "ready" | "failed";

export interface PairingQR {
  /** The attach URL the phone camera opens (cmux on iPhone dials this Mac). */
  url: string;
  /** A PNG data URL of the QR code for `url`. */
  image: string;
  /** Unix ms after which the host mints a new code. */
  expiresAt: number;
}

export interface MobilePairingStatus {
  state: PairingState;
  /** The signed-in account (email or name), when there is one. */
  account?: string;
  /** This Mac's name as phones list it. */
  macName: string;
  /** Phone access is on (`phone.allowConnections`). */
  allowed: boolean;
  /** Phones that connected since the listener started. */
  connectedPhones: number;
  /** The listener's own failure text (`failed` only). */
  failure?: string;
  /** Present once `ready` and this build has an iPhone app to address. */
  qr?: PairingQR;
}
