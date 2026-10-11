// l10n-allow-file: gallery fixtures, not shipped UI.
// Import/conflict review and a vault-lock screen are not implemented by this React page.
// Reveal, delete confirmation and export warning/auth/save sheets belong to the native host;
// these fixtures exercise their page outcomes through the real mock provider, never fake sheets.
import { minutesAgo } from "../../gallery/clock";
import { passwordsPageEntry, type PasswordsPageVariant } from "../../gallery/format";
import type { MockData } from "./mockProvider";
import { PasswordCodes, PasswordOps, type SavedPassword } from "./types";

const password = (id: string, site: string, username: string, extra: Partial<SavedPassword> = {}): SavedPassword => ({
  id,
  site,
  url: `https://${site}/`,
  username,
  created: minutesAgo(90 * 1440),
  last_used: minutesAgo(1440),
  times_used: 12,
  weak: false,
  reused: false,
  ...extra,
});
const data: MockData = {
  profiles: [
    { id: "default", name: "Personal" },
    { id: "work", name: "Atlas research and development" },
  ],
  sections: { passwords: true, passkeys: true, exceptions: true, export: true },
  passwords: {
    default: [
      password("atlas", "atlas.example.test", "sample-user"),
      password("atlas-work", "atlas.example.test", "sample-work", { reused: true, times_used: 48 }),
      password("archive", "archive.example.test", "", { weak: true, reused: true, last_used: null, times_used: 0 }),
    ],
    work: [password("work", "projects.example.test", "sample-researcher")],
  },
  passkeys: {
    default: [
      { id: "passkey-1", rp_id: "atlas.example.test", user_name: "sample-user", user_display_name: "Sample Person" },
    ],
    work: [],
  },
  exceptions: { default: [{ id: "exception-1", site: "kiosk.example.test" }], work: [] },
};
const row = '[data-id="atlas"]';
const action = (index: number) => `${row} .pw-row-button:nth-child(${index})`;
const click = (selector: string) => ({ selector, action: "click" as const });
const wait = (selector: string) => ({ selector, action: "wait" as const });
const variant = (extra: Omit<PasswordsPageVariant, "data"> = {}, fixture = data): PasswordsPageVariant => ({
  data: fixture,
  ...extra,
});
const failure = (op: string, code: string, message: string, selector = action(2)): PasswordsPageVariant =>
  variant({
    failure: { op, code, message },
    steps: [click(selector), wait(".pw-notice.failed")],
  });
const empty: MockData = { ...data, passwords: {}, passkeys: {}, exceptions: {} };
const many: MockData = {
  ...data,
  profiles: Array.from({ length: 24 }, (_, i) => ({
    id: i ? `profile-${i}` : "default",
    name: `Research profile ${i + 1} with a long descriptive name`,
  })),
  passwords: {
    default: Array.from({ length: 120 }, (_, i) =>
      password(
        `long-${i}`,
        `service-${String(i).padStart(3, "0")}.research-and-development.example.test`,
        `sample-user-with-a-long-display-name-${i}`,
        { weak: i % 5 === 0, reused: i % 7 === 0 },
      ),
    ),
  },
  passkeys: {
    default: Array.from({ length: 30 }, (_, i) => ({
      id: `passkey-${i}`,
      rp_id: `service-${i}.example.test`,
      user_name: `sample-${i}`,
      user_display_name: `Sample research account ${i}`,
    })),
  },
  exceptions: {
    default: Array.from({ length: 30 }, (_, i) => ({ id: `exception-${i}`, site: `kiosk-${i}.example.test` })),
  },
};

export default passwordsPageEntry({
  id: "pages.passwords",
  title: "Passwords",
  area: "Settings",
  height: 720,
  // Full-page surface: window mode's default `one`; widths also exercise standalone panes.
  widths: { narrow: 360, normal: 900, wide: 1440 },
  covers: ["page:cmux.passwords", "pages/passwords/PasswordsPage.tsx"],
  variants: {
    lists: variant({ note: "Passwords, passkeys and exceptions; metadata only, no secrets." }),
    empty: variant({}, empty),
    loading: variant({ loading: true }),
    "single-entry": variant(
      {},
      { ...empty, profiles: [data.profiles[0]!], passwords: { default: [data.passwords.default![0]!] } },
    ),
    "entry-selected": variant({
      steps: [click(action(3)), wait(".pw-username-input"), { selector: ".pw-username-input", action: "select" }],
    }),
    "search-focused": variant({ steps: [wait(row), { selector: ".pw-search", action: "focus" }] }),
    "search-matches": variant({ steps: [wait(row), { selector: ".pw-search", action: "input", value: "atlas" }] }),
    "search-empty": variant({ steps: [wait(row), { selector: ".pw-search", action: "input", value: "missing-site" }] }),
    "sort-recent": variant({
      steps: [wait(row), { selector: ".pw-search-row select", action: "change", value: "recent" }],
    }),
    "sort-most-used": variant({
      steps: [wait(row), { selector: ".pw-search-row select", action: "change", value: "mostUsed" }],
    }),
    "work-profile": variant({
      steps: [wait(row), { selector: ".pw-profile", action: "change", value: "work" }, wait('[data-id="work"]')],
    }),
    "long-lists": variant({}, many),
    "passkeys-and-exceptions": variant({}, { ...many, passwords: {} }),
    "exceptions-long": variant({}, { ...many, passwords: {}, passkeys: {} }),
    "update-required": variant(
      {},
      { ...data, sections: { passwords: false, passkeys: true, exceptions: false, export: false } },
    ),
    "all-unavailable": variant(
      {},
      { ...data, sections: { passwords: false, passkeys: false, exceptions: false, export: false } },
    ),
    "network-error": variant({
      failure: { op: PasswordOps.state, code: "cmux.protocol.closed", message: "The connection is unavailable." },
    }),
    "list-error": variant({
      failure: {
        op: PasswordOps.list,
        code: "cmux.passwords.failed",
        message: "The saved sign-ins could not be loaded.",
      },
    }),
    "permission-error": variant({ gesture: false, steps: [click(action(2)), wait(".pw-notice.failed")] }),
    locked: variant({
      note: "Device authentication refused; the page shows its real failure notice, not a vault screen.",
      authenticate: false,
      steps: [click(action(1)), wait(".pw-notice.failed")],
    }),
    "not-found": failure(PasswordOps.copy, PasswordCodes.notFound, "This item is no longer saved."),
    copied: variant({ steps: [click(action(2)), wait(".pw-notice.copied")] }),
    exported: variant({ steps: [wait(row), click(".pw-export"), wait(".pw-notice.exported")] }),
    "export-denied": variant({
      authenticate: false,
      steps: [wait(row), click(".pw-export"), wait(".pw-notice.failed")],
    }),
    "delete-cancelled": variant({
      confirm: false,
      steps: [click(action(4))],
      note: "Native confirmation declined; the saved entry remains.",
    }),
    "delete-completed": variant({
      steps: [click(action(4)), wait('[data-site="atlas.example.test"]:not(:has([data-id="atlas"]))')],
    }),
    "reveal-completed": variant({
      steps: [click(action(1))],
      note: "Native reveal completed. React never receives or displays a password.",
    }),
  },
});
