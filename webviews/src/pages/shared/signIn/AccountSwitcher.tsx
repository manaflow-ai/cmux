// The account list for in-place sign-in: one group per provider (GitHub, ChatGPT, Claude), every
// account with its state, Use (make it the default), Sign out and Remove, and one Add account per
// provider. Pure props; the caller runs each gesture (settings/components/AccountSignInSection.tsx).
// A running sign-in draws the device card (DeviceSignInCard) where `look` puts it: inside the row
// (inline), over the page (sheet) or as one strip over the list (strip).
import { Button } from "../../../ui/Button";
import { ACCOUNT_FAMILIES, type AccountFamily, type AccountRowWire, type SignInView } from "./accountSignIn";
import { DeviceSignInCard, ProviderMark, type DeviceSignInCardProps, type SignInLook } from "./DeviceSignInCard";
import { useSignInStrings } from "./strings";

/** The sign-in the list is running: its provider, the row it signs in (null: a new account) and its view. */
export type ActiveSignIn = { family: AccountFamily; account: string | null; view: SignInView };

export type AccountSwitcherProps = {
  accounts: readonly AccountRowWire[];
  signIn?: ActiveSignIn | null;
  look?: SignInLook;
  /** Provider add rows already surfaced by a dedicated settings card. */
  hideAddFamilies?: readonly AccountFamily[];
  /** An account a gesture runs on (its buttons wait). */
  busy?: string | null;
  onAdd?(family: AccountFamily): void;
  onSignIn?(account: AccountRowWire): void;
  onUse?(account: AccountRowWire): void;
  onSignOut?(account: AccountRowWire): void;
  onRemove?(account: AccountRowWire): void;
  /** The card's gestures (DeviceSignInCard). */
  card?: Omit<DeviceSignInCardProps, "family" | "view" | "look">;
};

const GROUP_KEY: Record<AccountFamily, string> = {
  github: "signIn.group.github",
  codex: "signIn.group.codex",
  claude: "signIn.group.claude",
};

export function AccountSwitcher(props: AccountSwitcherProps) {
  const { accounts, signIn = null, look = "inline", busy = null, hideAddFamilies = [] } = props;
  const strings = useSignInStrings();
  const card = (active: ActiveSignIn) => (
    <DeviceSignInCard family={active.family} view={active.view} look={look} {...props.card} />
  );
  // A new account's row arrives with the start; until then (or for a host that adds it on finish)
  // the card sits under its provider's Add account.
  const onRow = (row: AccountRowWire) => signIn !== null && signIn.account === row.id;
  const underAdd = (family: AccountFamily) =>
    signIn !== null &&
    signIn.family === family &&
    (signIn.account === null || !accounts.some((row) => row.id === signIn.account));
  return (
    <div className="signin-accounts" data-sign-in-look={look}>
      {look === "strip" && signIn && card(signIn)}
      {look === "sheet" && signIn && card(signIn)}
      {ACCOUNT_FAMILIES.map((family) => {
        const rows = accounts.filter((row) => row.family === family);
        const signingHere = signIn?.family === family;
        return (
          <section className="group" key={family} data-sign-in-family={family}>
            <h3 className="group-title">{strings.t(GROUP_KEY[family])}</h3>
            <div className="rows">
              {rows.length === 0 && (
                <div className="row accounts-row signin-none">
                  <span className="row-help">{strings.t("signIn.account.none")}</span>
                </div>
              )}
              {rows.map((row) => {
                const waits = busy === row.id || (signingHere && onRow(row));
                return (
                  <div className="row accounts-row" key={row.id} data-sign-in-account={row.id}>
                    <div className="row-main">
                      <ProviderMark family={family} />
                      <div className="row-label">
                        <div className="row-title">{row.name}</div>
                        {(row.email && row.email !== row.name) || row.plan || row.builtin ? (
                          <div className="row-help">
                            {[
                              row.email && row.email !== row.name ? row.email : null,
                              row.plan ?? null,
                              row.builtin ? strings.t("signIn.account.cliLogin") : null,
                            ]
                              .filter(Boolean)
                              .join(" · ")}
                          </div>
                        ) : null}
                      </div>
                      {row.default && row.signedIn ? (
                        <span className="accounts-badge" data-sign-in-default="">
                          {strings.t("signIn.account.default")}
                        </span>
                      ) : !row.signedIn ? (
                        <span className="accounts-status" data-status="warning">
                          <span className="accounts-dot" aria-hidden="true" />
                          {strings.t("signIn.account.signedOut")}
                        </span>
                      ) : null}
                      <span className="accounts-buttons">
                        {row.signedIn && !row.default && (
                          <Button
                            size="sm"
                            disabled={waits}
                            data-sign-in-row-action="use"
                            onClick={() => props.onUse?.(row)}
                          >
                            {strings.t("signIn.account.use")}
                          </Button>
                        )}
                        {row.signedIn ? (
                          <Button
                            size="sm"
                            disabled={waits}
                            data-sign-in-row-action="signOut"
                            onClick={() => props.onSignOut?.(row)}
                          >
                            {strings.t("signIn.account.signOut")}
                          </Button>
                        ) : (
                          <Button
                            size="sm"
                            variant="solid"
                            disabled={waits}
                            data-sign-in-row-action="signIn"
                            onClick={() => props.onSignIn?.(row)}
                          >
                            {strings.t("signIn.account.signIn")}
                          </Button>
                        )}
                        {!row.builtin && (
                          <Button
                            size="sm"
                            danger
                            disabled={waits}
                            data-sign-in-row-action="remove"
                            onClick={() => props.onRemove?.(row)}
                          >
                            {strings.t("signIn.account.remove")}
                          </Button>
                        )}
                      </span>
                    </div>
                    {look === "inline" && signIn && onRow(row) && <div className="accounts-body">{card(signIn)}</div>}
                  </div>
                );
              })}
              {!hideAddFamilies.includes(family) && (
                <div className="row accounts-row signin-add" data-sign-in-add={family}>
                  <div className="row-main">
                    <span className="accounts-buttons">
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={signingHere}
                        data-sign-in-row-action="add"
                        onClick={() => props.onAdd?.(family)}
                      >
                        {strings.t("signIn.account.add")}
                      </Button>
                    </span>
                  </div>
                  {look === "inline" && signIn && underAdd(family) && (
                    <div className="accounts-body">{card(signIn)}</div>
                  )}
                </div>
              )}
            </div>
          </section>
        );
      })}
    </div>
  );
}
