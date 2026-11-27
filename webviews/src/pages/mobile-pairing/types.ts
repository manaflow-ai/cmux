// The Mobile Pairing page's ops (cmux-page://cmux.mobile-pairing/, palette "Open Mobile Pairing"):
// the app answers them from its iPhone host (IPhoneHostService, the bundled cmux-mobile-host that
// cmux on iPhone connects through; MobilePairingPageProvider.swift).

export const MobilePairingOps = {
  /** `{}` → `MobilePairingStatus`. */
  status: "cmux.mobilePairing.status",
  /** `{on}` → `{}`: Settings > Accounts > Allow iPhone Connections. Only after the person's own click. */
  setAllowed: "cmux.mobilePairing.setAllowed",
  /** `{id, allow}` → `{}`: Allow or Don't Allow on a phone's waiting request. Only after the person's own click. */
  answerPair: "cmux.mobilePairing.answerPair",
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
  /** This Mac's pairing link (`cmux-next://pair?mac=&team=&name=&t=&k=&e=`), which cmux on iPhone opens
   * from the camera or its own scanner. Sent only while the host is online. */
  url: string;
  /** A PNG data URL of the QR code for `url`. */
  image: string;
  /** Unix ms when the page asks for a new code: a minute before this one's token expires. */
  expiresAt: number;
}

export interface MobilePairingStatus {
  state: PairingState;
  /** The signed-in account (email or name), when there is one. */
  account?: string;
  /** This Mac's name as phones list it. */
  macName: string;
  /** iPhone connections are on (`mobile.allowIPhoneConnections`). */
  allowed: boolean;
  /** Phones connected now. */
  connectedPhones: number;
  /** The iPhone host's own words (localized by the host); absent from an older host. */
  host?: PairingHost;
  /** The listener's own failure text (`failed` only). */
  failure?: string;
  /** A code for the iPhone camera; the host sends none until cmux on iPhone opens a pairing link. */
  qr?: PairingQR;
}

/** One phone the account knows, or one connected now. */
export interface PairingPhone {
  id: string;
  title: string;
  subtitle: string;
  connected: boolean;
}

/** A phone asking to connect: Allow or Don't Allow answers it. */
export interface PairingRequest {
  id: string;
  title: string;
  subtitle: string;
}

export interface PairingHost {
  /** The host's status line ("Online · 1 phone connected"). */
  status?: string;
  /** How a phone connects: install cmux on the iPhone and sign in with the same account. */
  how?: string;
  phonesTitle?: string;
  phones: PairingPhone[];
  phonesEmpty?: string;
  /** Why the phone list could not be read; shown instead of `phonesEmpty`. */
  phonesError?: string | null;
  pendingTitle?: string;
  pending: PairingRequest[];
  allowTitle?: string;
  denyTitle?: string;
  /** Requests this Mac stopped asking about for a while (after Don't Allow). */
  blocked?: string | null;
}
