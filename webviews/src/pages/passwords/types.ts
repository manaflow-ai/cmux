// Wire types of the `cmux.passwords/1` ops (plans/cmux-next/passwords.md 1.4). The Swift provider
// in the app serves them (CmuxNextApp/Passwords/PasswordsPageProvider.swift); the mock provider
// (mockProvider.ts) serves the same contract. Every reply is metadata: no op returns a password.

export const PasswordOps = {
  state: "cmux.passwords.state",
  list: "cmux.passwords.list",
  passkeysList: "cmux.passwords.passkeys.list",
  exceptionsList: "cmux.passwords.exceptions.list",
  usernameSet: "cmux.passwords.username.set",
  remove: "cmux.passwords.remove",
  passkeyRemove: "cmux.passwords.passkey.remove",
  exceptionRemove: "cmux.passwords.exception.remove",
  /** The app shows the password in a native sheet after device owner authentication. */
  reveal: "cmux.passwords.reveal",
  /** The app copies the password to the pasteboard after device owner authentication. */
  copy: "cmux.passwords.copy",
  /** Native warning, device owner authentication and save panel, then the app writes the CSV. */
  export: "cmux.passwords.export",
  changed: "cmux.passwords.changed",
} as const;

export const PasswordCodes = {
  /** The running build cannot do this yet ("Available after the next update"). */
  unavailable: "cmux.passwords.unavailable",
  /** A write without the person's click or key in the page. */
  userOnly: "cmux.passwords.user_only",
  notFound: "cmux.passwords.not_found",
  authFailed: "cmux.passwords.auth_failed",
  /** Export while `browser.passwords.allowExport` is off. */
  exportOff: "cmux.passwords.export_off",
  /** The person declined the native sheet. */
  cancelled: "cmux.page.cancelled",
} as const;

export interface Profile {
  id: string;
  name: string;
}

export type SectionName = "passwords" | "passkeys" | "exceptions";

export interface Sections {
  passwords: boolean;
  passkeys: boolean;
  exceptions: boolean;
  export: boolean;
}

export interface StateResult {
  profiles: Profile[];
  /** The profile shown first. */
  profile: string;
  sections: Sections;
  /** `browser.passwords.allowExport` (default off): Export works only while it is on. */
  export_allowed: boolean;
}

export interface SavedPassword {
  id: string;
  site: string;
  url: string;
  username: string;
  /** Milliseconds since 1970, or null. */
  created: number | null;
  last_used: number | null;
  times_used: number;
  weak: boolean;
  reused: boolean;
}

export interface SavedPasskey {
  id: string;
  rp_id: string;
  user_name: string;
  user_display_name: string;
}

export interface PasswordException {
  id: string;
  site: string;
}

export interface ChangedEvent {
  profile: string;
  revision: number;
}
