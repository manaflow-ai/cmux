// The Passwords page (plans/cmux-next/passwords.md 1.4). State lives in `PasswordsStore`; this
// file renders it and turns clicks and form submits into store intents. It never shows a password:
// Show and Copy ask the app, which authenticates the person and uses a native sheet or the
// pasteboard. Keys belong to the app's key dispatcher; the page handles none itself.
import { useSyncExternalStore, type FormEvent } from "react";
import type { Strings } from "../shared/i18n";
import {
  filterExceptions,
  filterPasskeys,
  filterPasswords,
  groupBySite,
  siteInitial,
  sortExceptions,
  sortPasskeys,
  type SortMode,
} from "./model";
import type { PasswordsStore } from "./store";
import type { SavedPassword } from "./types";

const focusOnMount = (node: HTMLInputElement | null) => node?.focus();
const editOnMount = (node: HTMLInputElement | null) => {
  if (!node) return;
  node.focus();
  node.select();
};

const ICONS = {
  // Eye.
  reveal:
    "M1.75 8S4.25 3.5 8 3.5 14.25 8 14.25 8 11.75 12.5 8 12.5 1.75 8 1.75 8ZM8 6.25a1.75 1.75 0 1 0 0 3.5 1.75 1.75 0 0 0 0-3.5Z",
  // Two sheets.
  copy: "M5.5 5.5h7v8h-7ZM3.5 10.5v-8h7",
  // Pencil.
  edit: "M10.75 2.75 13.25 5.25 5.5 13H3v-2.5ZM9 4.5l2.5 2.5",
  // Trash.
  delete: "M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.75 9h5.5l.75-9",
  // Cross.
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
};

function Icon({ name }: { name: keyof typeof ICONS }) {
  return (
    <svg className="pw-icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d={ICONS[name]}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function RowButton({ icon, label, onClick }: { icon: keyof typeof ICONS; label: string; onClick: () => void }) {
  return (
    <button type="button" className="pw-row-button" aria-label={label} title={label} onClick={onClick}>
      <Icon name={icon} />
    </button>
  );
}

function Unavailable({ text }: { text: string }) {
  return <p className="pw-unavailable">{text}</p>;
}

export function PasswordsPage({ store, strings }: { store: PasswordsStore; strings: Strings }) {
  const snap = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = strings;
  const disconnected = snap.connection === "disconnected";
  const passwords = groupBySite(filterPasswords(snap.passwords, snap.text), snap.sort);
  const passkeys = sortPasskeys(filterPasskeys(snap.passkeys, snap.text));
  const exceptions = sortExceptions(filterExceptions(snap.exceptions, snap.text));
  const searching = snap.text.trim().length > 0;
  const dates = new Intl.DateTimeFormat(strings.language, { dateStyle: "medium" });

  const empty = (key: string) => <p className="pw-empty">{searching ? t("passwords.page.noMatches") : t(key)}</p>;

  // Return submits the editor's form; Escape reaches the page as the dispatcher's `reset` command
  // (main.tsx), and leaving the field cancels. The page reads no key events itself.
  const submitUsername = (row: SavedPassword) => (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const field = event.currentTarget.elements.namedItem("username") as HTMLInputElement | null;
    void store.commitUsername(row, field?.value ?? row.username);
  };

  const notice = snap.notice && (
    <output className={`pw-notice ${snap.notice.kind}`}>
      <span>
        {snap.notice.kind === "copied"
          ? t("passwords.page.copied")
          : snap.notice.kind === "exported"
            ? t("passwords.page.exported")
            : strings.format("passwords.page.failed", snap.notice.message)}
      </span>
      <button
        type="button"
        className="pw-row-button"
        aria-label={t("passwords.page.cancel")}
        onClick={() => store.dismissNotice()}
      >
        <Icon name="close" />
      </button>
    </output>
  );

  return (
    <div className="pw-page">
      <header className="pw-header" data-titlebar>
        <div className="pw-title-row">
          <h1 className="pw-title">{t("passwords.page.title")}</h1>
          {snap.profiles.length > 1 && (
            <select
              className="pw-select pw-profile"
              aria-label={t("passwords.page.profile")}
              value={snap.profile}
              onChange={(event) => store.setProfile(event.currentTarget.value)}
            >
              {snap.profiles.map((profile) => (
                <option key={profile.id} value={profile.id}>
                  {profile.name}
                </option>
              ))}
            </select>
          )}
          <button
            type="button"
            className="pw-button pw-export"
            disabled={!snap.sections.export || disconnected}
            title={snap.sections.export ? undefined : t("passwords.page.availableAfterUpdate")}
            onClick={() => void store.exportAll()}
          >
            {t("passwords.page.export")}
          </button>
        </div>
        <div className="pw-search-row">
          <input
            ref={focusOnMount}
            className="pw-search"
            type="search"
            placeholder={t("passwords.page.search")}
            aria-label={t("passwords.page.search")}
            value={snap.text}
            onChange={(event) => store.setText(event.currentTarget.value)}
          />
          <select
            className="pw-select"
            aria-label={t("passwords.page.sort")}
            value={snap.sort}
            disabled={!snap.sections.passwords}
            onChange={(event) => store.setSort(event.currentTarget.value as SortMode)}
          >
            <option value="site">{t("passwords.page.sort.site")}</option>
            <option value="recent">{t("passwords.page.sort.recent")}</option>
            <option value="mostUsed">{t("passwords.page.sort.mostUsed")}</option>
          </select>
        </div>
      </header>
      {notice}
      <div className="pw-scroll">
        {disconnected ? (
          <p className="pw-empty pw-disconnected">{t("passwords.page.disconnected")}</p>
        ) : snap.loading ? (
          <p className="pw-empty">{t("passwords.page.loading")}</p>
        ) : (
          <>
            <section className="pw-section" aria-labelledby="pw-passwords">
              <h2 id="pw-passwords" className="pw-section-title">
                {t("passwords.page.section.passwords")}
              </h2>
              {!snap.sections.passwords ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : passwords.length === 0 ? (
                empty("passwords.page.empty.passwords")
              ) : (
                passwords.map((group) => (
                  <div key={group.site} className="pw-site" data-site={group.site}>
                    <div className="pw-site-header">
                      <span className="pw-site-badge" aria-hidden="true">
                        {siteInitial(group.site)}
                      </span>
                      <span className="pw-site-name">{group.site}</span>
                    </div>
                    {group.rows.map((row) => (
                      <div key={row.id} className="pw-row" data-id={row.id}>
                        {snap.editing === row.id ? (
                          <form className="pw-username-form" onSubmit={submitUsername(row)}>
                            <input
                              ref={editOnMount}
                              name="username"
                              className="pw-username-input"
                              aria-label={t("passwords.page.editUsername")}
                              defaultValue={row.username}
                              onBlur={() => store.cancelEdit()}
                            />
                          </form>
                        ) : (
                          <span className={row.username ? "pw-username" : "pw-username none"}>
                            {row.username || t("passwords.page.noUsername")}
                          </span>
                        )}
                        <span className="pw-badges">
                          {row.weak && <span className="pw-badge">{t("passwords.page.weak")}</span>}
                          {row.reused && <span className="pw-badge">{t("passwords.page.reused")}</span>}
                        </span>
                        <span className="pw-meta">
                          {row.last_used == null
                            ? t("passwords.page.neverUsed")
                            : strings.format("passwords.page.lastUsed", dates.format(new Date(row.last_used)))}
                        </span>
                        <span className="pw-actions">
                          <RowButton
                            icon="reveal"
                            label={t("passwords.page.reveal")}
                            onClick={() => void store.reveal(row)}
                          />
                          <RowButton
                            icon="copy"
                            label={t("passwords.page.copy")}
                            onClick={() => void store.copy(row)}
                          />
                          <RowButton
                            icon="edit"
                            label={t("passwords.page.editUsername")}
                            onClick={() => store.editUsername(row)}
                          />
                          <RowButton
                            icon="delete"
                            label={t("passwords.page.delete")}
                            onClick={() => void store.removePassword(row)}
                          />
                        </span>
                      </div>
                    ))}
                  </div>
                ))
              )}
            </section>
            <section className="pw-section" aria-labelledby="pw-passkeys">
              <h2 id="pw-passkeys" className="pw-section-title">
                {t("passwords.page.section.passkeys")}
              </h2>
              <p className="pw-help">{t("passwords.page.passkeysHelp")}</p>
              {!snap.sections.passkeys ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : passkeys.length === 0 ? (
                empty("passwords.page.empty.passkeys")
              ) : (
                passkeys.map((row) => (
                  <div key={row.id} className="pw-row" data-id={row.id}>
                    <span className="pw-site-badge" aria-hidden="true">
                      {siteInitial(row.rp_id)}
                    </span>
                    <span className="pw-site-name">{row.rp_id}</span>
                    <span className="pw-username">{row.user_display_name || row.user_name}</span>
                    <span className="pw-actions">
                      <RowButton
                        icon="delete"
                        label={t("passwords.page.delete")}
                        onClick={() => void store.removePasskey(row)}
                      />
                    </span>
                  </div>
                ))
              )}
            </section>
            <section className="pw-section" aria-labelledby="pw-exceptions">
              <h2 id="pw-exceptions" className="pw-section-title">
                {t("passwords.page.section.exceptions")}
              </h2>
              <p className="pw-help">{t("passwords.page.exceptionsHelp")}</p>
              {!snap.sections.exceptions ? (
                <Unavailable text={t("passwords.page.availableAfterUpdate")} />
              ) : exceptions.length === 0 ? (
                empty("passwords.page.empty.exceptions")
              ) : (
                exceptions.map((row) => (
                  <div key={row.id} className="pw-row" data-id={row.id}>
                    <span className="pw-site-badge" aria-hidden="true">
                      {siteInitial(row.site)}
                    </span>
                    <span className="pw-site-name">{row.site}</span>
                    <span className="pw-actions">
                      <RowButton
                        icon="delete"
                        label={t("passwords.page.remove")}
                        onClick={() => void store.removeException(row)}
                      />
                    </span>
                  </div>
                ))
              )}
            </section>
          </>
        )}
      </div>
    </div>
  );
}
