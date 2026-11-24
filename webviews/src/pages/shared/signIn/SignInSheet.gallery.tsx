// l10n-allow-file: gallery fixtures (sample codes and accounts), not shipped UI.
// Variant B: a dialog over Settings, like Connect Claude: the mark, the big code and three steps.
// One variant per state (galleryFixtures.ts), each with its one action.
import { componentEntry } from "../../../gallery/format";
import { SIGN_IN_STATES, type SignInStateName } from "./galleryFixtures";

type Props = { state: SignInStateName };

async function load() {
  const { DeviceSignInCard } = await import("./DeviceSignInCard");
  const { SIGN_IN_STATES: states, SIGN_IN_STATE_FAMILY: family } = await import("./galleryFixtures");
  const noop = () => {};
  return function SignInSheet({ state }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group">
          <div className="rows">
            <div className="row accounts-row">
              <DeviceSignInCard
                family={family[state]}
                view={states[state]}
                look="sheet"
                onCopy={noop}
                onCancel={noop}
                onRetry={noop}
                onDone={noop}
                onInstall={noop}
                onSubmitCode={noop}
              />
            </div>
          </div>
        </section>
      </section>
    );
  };
}

const NOTES: Record<SignInStateName, string> = {
  starting: "Right after the click: getting a code. Cancel only.",
  code: "ChatGPT: the code, already on the clipboard; the page is open beside the window. Copy again or Cancel.",
  "code-not-copied": "GitHub, when the clipboard refused: the code to type. Copy or Cancel.",
  approve: "Claude's page signs in by itself: approve there. Cancel only.",
  paste: "Claude's page shows a code to paste back here. Continue once pasted.",
  "signed-in": "Turned into the account by itself. Done (it also closes after a few seconds).",
  expired: "The code ran out unused. New Code.",
  cancelled: "Cancelled on the provider's page. Try again.",
  "shared-machine": "A shared team machine refuses a personal sign-in. Done.",
  failed: "Anything else. Try again.",
  "not-installed": "The provider's CLI is missing on this Mac. Install.",
};

export default componentEntry<Props>({
  id: "settings.sign-in-sheet",
  title: "Device sign-in, as a sheet",
  area: "Settings",
  height: 420,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/shared/signIn/DeviceSignInCard.tsx", "pages/shared/signIn/galleryFixtures.ts#SIGN_IN_STATES"],
  keywords: ["login", "device code", "account", "gh auth", "codex", "claude"],
  load,
  styles: () => import("../../settings/page.css"),
  variants: Object.fromEntries(
    (Object.keys(SIGN_IN_STATES) as SignInStateName[]).map((state) => [
      state,
      { note: NOTES[state], props: { state } },
    ]),
  ) as Record<SignInStateName, { note: string; props: Props }>,
});
