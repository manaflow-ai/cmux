// Settings > Browser > Autofill and passwords (Lawrence 2026-10-28: "use native chrome UIs and
// functionality for both of them"): Password Manager and Contact Info, each with Manage, which
// opens Chromium's own page (chrome://password-manager, chrome://settings/addresses) in a Chromium
// tab of the chosen browser profile. The pages edit the profile's real stores: the passwords the
// save prompt writes and the addresses, phone numbers and emails autofill fills. Manage runs the
// catalog action the palette and the profile menu run (`browserProfile.managePasswords`,
// `browserProfile.manageAddresses`); this page only picks the profile.
import { useState } from "react";
import { useSettingsState, useStore } from "../context";
import type { BrowserProfile } from "../ops";
import { queryTerms } from "../search";
import { t } from "../strings";
import { ActionRow } from "./ActionRow";

const PAGES = [
  {
    id: "passwords",
    action: "browserProfile.managePasswords",
    title: "settingsWindow.autofill.passwords",
    help: "settingsWindow.autofill.passwordsHelp",
  },
  {
    id: "addresses",
    action: "browserProfile.manageAddresses",
    title: "settingsWindow.autofill.addresses",
    help: "settingsWindow.autofill.addressesHelp",
  },
] as const;

/** Words a search finds the card by, besides its localized text (English, as rows' keys are). */
const KEYWORDS = [
  "autofill",
  "password",
  "passwords",
  "password manager",
  "passkeys",
  "address",
  "addresses",
  "contact info",
  "phone",
  "email",
];

/** True when every term of `query` is in the card's title, rows, help or keywords. */
export function autofillCardMatches(query: string): boolean {
  const terms = queryTerms(query);
  if (terms.length === 0) return false;
  const haystack = [
    t("settingsWindow.autofill"),
    ...PAGES.flatMap((page) => [t(page.title), t(page.help)]),
    ...KEYWORDS,
  ]
    .join("\n")
    .toLowerCase();
  return terms.every((term) => haystack.includes(term));
}

export function AutofillCard() {
  const { host } = useSettingsState();
  const store = useStore();
  const profiles: BrowserProfile[] = host?.browser_profiles ?? [];
  const fallback = profiles.find((profile) => profile.is_default) ?? profiles[0];
  const [picked, setPicked] = useState<string | null>(null);
  // A picked profile that was deleted falls back to the default one.
  const profile = profiles.find((candidate) => candidate.id === picked) ?? fallback;
  return (
    <section className="group" data-card="autofill">
      <h3 className="group-title">{t("settingsWindow.autofill")}</h3>
      <div className="rows">
        {profiles.length > 1 && (
          <ActionRow title={t("settingsWindow.autofill.profile")} help="">
            <select
              className="field"
              data-autofill-profile=""
              aria-label={t("settingsWindow.autofill.profile")}
              value={profile?.id ?? ""}
              onChange={(event) => setPicked(event.target.value)}
            >
              {profiles.map((candidate) => (
                <option key={candidate.id} value={candidate.id}>
                  {candidate.name}
                </option>
              ))}
            </select>
          </ActionRow>
        )}
        {PAGES.map((page) => (
          <ActionRow key={page.id} title={t(page.title)} help={t(page.help)} data={{ "data-autofill": page.id }}>
            <button
              type="button"
              className="button"
              data-manage=""
              disabled={!profile}
              onClick={() => {
                if (profile) void store.runAction(page.action, {}, `browser-profile:${profile.id}`);
              }}
            >
              {t("settingsWindow.autofill.manage")}
            </button>
          </ActionRow>
        ))}
      </div>
    </section>
  );
}
