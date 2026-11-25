// l10n-allow-file: gallery fixtures (sample accounts), not shipped UI.
// The account list for in-place sign-in: GitHub, ChatGPT and Codex, Claude, each with its accounts,
// the default marked, Use, Sign out and Remove, and one Add account per provider. The last
// variants run a sign-in in each placement (inline, sheet, strip) over the same list.
import { componentEntry } from "../../../gallery/format";
import type { AccountListName, SignInStateName } from "./galleryFixtures";
import type { SignInLook } from "./DeviceSignInCard";

type Props = {
  list: AccountListName;
  look?: SignInLook;
  /** A sign-in in progress: its state, and the row (absent: a new account under Add account). */
  signing?: SignInStateName;
  account?: string;
};

async function load() {
  const { AccountSwitcher } = await import("./AccountSwitcher");
  const { ACCOUNT_LISTS, SIGN_IN_STATES, SIGN_IN_STATE_FAMILY } = await import("./galleryFixtures");
  const noop = () => {};
  return function AccountSwitcherStage({ list, look = "inline", signing, account }: Props) {
    const accounts = ACCOUNT_LISTS[list];
    const family = account
      ? (accounts.find((row) => row.id === account)?.family ?? "codex")
      : signing
        ? SIGN_IN_STATE_FAMILY[signing]
        : "codex";
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <AccountSwitcher
          accounts={accounts}
          look={look}
          signIn={signing ? { family, account: account ?? null, view: SIGN_IN_STATES[signing] } : null}
          onAdd={noop}
          onSignIn={noop}
          onUse={noop}
          onSignOut={noop}
          onRemove={noop}
          card={{ onCopy: noop, onCancel: noop, onRetry: noop, onDone: noop, onInstall: noop, onSubmitCode: noop }}
        />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.account-switcher",
  title: "Accounts: GitHub, ChatGPT and Claude",
  area: "Settings",
  height: 640,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/shared/signIn/AccountSwitcher.tsx", "pages/shared/signIn/galleryFixtures.ts#ACCOUNT_LISTS"],
  keywords: ["login", "account switcher", "sign in", "gh auth", "codex", "claude"],
  load,
  styles: () => import("../../settings/page.css"),
  variants: {
    none: { note: "No account yet: each provider offers Add account only.", props: { list: "none" } },
    "one-each": {
      note: "One account each, each the default (the CLI's own login is marked).",
      props: { list: "oneEach" },
    },
    "two-each": { note: "Two per provider: the default marked, the other offers Use.", props: { list: "twoEach" } },
    "signed-out": {
      note: "One signed out: Sign in in its row (Use waits until it is signed in).",
      props: { list: "signedOut" },
    },
    "signing-inline": {
      note: "Variant A in place: Sign in on the signed-out ChatGPT row opens the code under it.",
      props: { list: "signedOut", look: "inline", signing: "code", account: "codex-1" },
    },
    "adding-inline": {
      note: "Variant A for a new account: the card under GitHub's Add account.",
      props: { list: "oneEach", look: "inline", signing: "code-not-copied" },
    },
    "signing-sheet": {
      note: "Variant B: the same sign-in as a sheet over the list.",
      props: { list: "signedOut", look: "sheet", signing: "code", account: "codex-1" },
    },
    "signing-strip": {
      note: "Variant C: the same sign-in as one strip over the list.",
      props: { list: "signedOut", look: "strip", signing: "code", account: "codex-1" },
    },
  },
});
