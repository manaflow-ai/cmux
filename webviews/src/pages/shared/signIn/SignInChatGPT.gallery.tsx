// l10n-allow-file: gallery fixtures (a sample account), not shipped UI.
// A ChatGPT account right after it signed in, in each arm of `chatgpt-signed-in`
// (chatgptSignedIn.experiment.ts), inline in its account row and as the sheet. Leo, 2026-11-25:
// "it should just follow at least basic styling or guidance for signed in with chatgpt type stuff".
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { chatgptSignedInLook } from "./chatgptSignedIn.experiment";

type Arm = "plan" | "account" | "row";
/** `arm` pins one arm; without it the card runs the experiment's arm (Compare arms sets it). */
type Props = { arm?: Arm; look: "inline" | "sheet" };

async function load() {
  const { DeviceSignInCard } = await import("./DeviceSignInCard");
  const noop = () => {};
  return function SignInChatGPT({ arm, look }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group">
          <div className="rows">
            <div className="row accounts-row">
              <DeviceSignInCard
                family="codex"
                view={{ state: "signedIn", account: "you@example.com" }}
                look={look}
                chatgptArm={arm}
                onDone={noop}
              />
            </div>
          </div>
        </section>
      </section>
    );
  };
}

const ARM_NOTES: Record<Arm, string> = {
  plan: "Plan notice (default): OpenAI's welcome notice, the account, Manage usage and Got It.",
  account: "Account card: the account first with a check on the ChatGPT tile, then the plan line.",
  row: "Compact row: like a connected-account row, Manage usage and Done trailing.",
};

const variants: Record<string, { note: string; props: Props }> = {
  inline: { note: "The running arm, inline in the account row (Compare arms switches it).", props: { look: "inline" } },
  sheet: { note: "The running arm, as the sheet (Compare arms switches it).", props: { look: "sheet" } },
};
for (const arm of ["plan", "account", "row"] as Arm[])
  for (const look of ["inline", "sheet"] as const)
    variants[`${arm}-${look}`] = { note: `${ARM_NOTES[arm]} (${look})`, props: { arm, look } };

/// Waits for the signed-in card, so each arm is captured once it drew.
const showSignedIn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".signin-chatgpt"));
};

export default componentEntry<Props>({
  id: "settings.sign-in-chatgpt",
  title: "ChatGPT signed in",
  area: "Settings",
  height: 360,
  widths: { narrow: 420, normal: 720 },
  covers: [
    "pages/shared/signIn/DeviceSignInCard.tsx#ChatGPTSignedIn",
    "pages/shared/signIn/chatgptSignedIn.experiment.ts",
  ],
  keywords: ["login", "chatgpt", "codex", "openai", "signed in", "plan", "usage"],
  load,
  styles: () => import("../../settings/page.css"),
  variants,
  experimental: true,
  experiment: { definition: chatgptSignedInLook, script: [{ name: "Signed in", run: showSignedIn }] },
});
