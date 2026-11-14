// l10n-allow-file: gallery fixtures (a sample prompt, machine names and the host's words), not shipped UI.
//
// A Cloud start's question in its card (CloudStartAsk.tsx), under the person's message: never a dialog
// over the window. Compare arms shows the three layouts of the `cloud-start-ask` experiment for each
// question the host asks during a start.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { cloudStartAskLook } from "./cloudStartAsk.experiment";
import { CloudStartView } from "./CloudStartView";
import type { CloudStartAsk, CloudStartProgress } from "./cloudStartProgress";

const begun: CloudStartProgress = {
  key: "gallery",
  task: "Run the sidebar tests and fix what fails.",
  state: "starting",
  folder: "paint",
};

const decline = { id: "cancel", title: "Cancel", role: "cancel" } as const;
const asks: Record<string, CloudStartAsk> = {
  firstLogin: {
    id: "a1",
    kind: "firstLogin",
    title: "Set up Claude on paint-dev?",
    lines: [
      "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for Personal account.",
      "Cloud machines you own later get this login with no prompt.",
    ],
    buttons: [decline, { id: "setUp", title: "Set Up", role: "default" }],
  },
  loginCopy: {
    id: "a2",
    kind: "loginCopy",
    title: "Use my Claude login on my own Cloud machines?",
    lines: [
      "cmux copies your own Claude login from this Mac to Cloud machines you own, so their chats start signed in. It never goes to team or shared machines, and cmux never stores it.",
      "You can turn this off in Settings > Machines. Without it, each machine offers Sign in to Claude.",
    ],
    buttons: [
      { id: "cancel", title: "Don't Use", role: "cancel" },
      { id: "use", title: "Use My Login", role: "default" },
    ],
  },
  codexConsent: {
    id: "a3",
    kind: "codexConsent",
    title: "Use my Codex login on my own Cloud machines?",
    lines: [
      "cmux gives Cloud machines you own short-lived access from the Codex sign-in on this Mac. This Mac keeps the refresh token, so you stay signed in here, and cmux never stores it.",
      "You can turn this off in Settings > Machines.",
    ],
    buttons: [
      { id: "cancel", title: "Don't Use", role: "cancel" },
      { id: "use", title: "Use My Login", role: "default" },
    ],
  },
  codexDevice: {
    id: "a4",
    kind: "codexDevice",
    title: "Sign in to Codex",
    lines: [
      "Use Codex sign-in on this Mac. Enter this one-time code: WXYZ-1234",
      "Only short-lived access moves to the VM; the refresh token stays on this Mac. Keep cmux running on this Mac to renew Codex access.",
    ],
    buttons: [decline, { id: "signedIn", title: "I signed in", role: "default" }],
    code: "WXYZ-1234",
    link: { url: "https://auth.openai.com/codex/device", title: "Open sign-in" },
  },
  recoverCredentials: {
    id: "a5",
    kind: "firstLogin",
    title: "Set up Claude on paint-dev?",
    lines: [
      "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for Personal account.",
      "This replaces Claude's login on this VM and restarts this chat before retrying its failed prompt.",
    ],
    buttons: [decline, { id: "transfer", title: "Transfer and restart", role: "default" }],
  },
};

const answered = async () => true;

const showAsk: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cloud-ask"));
};

export default componentEntry<ComponentProps<typeof CloudStartView>>({
  id: "agent-pane.cloud-start-ask",
  title: "Cloud start question",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: ["agent-session/acpmux/CloudStartAsk.tsx"],
  keywords: ["cloud", "start", "login", "consent", "codex", "device code", "sign in"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]),
  load: () => import("./CloudStartView").then((module) => module.CloudStartView),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  variants: {
    "first-login": {
      note: "A Claude start with no login cmux holds yet: one Set Up in the card, under the message.",
      props: { start: { ...begun, ask: asks.firstLogin! }, onAnswer: answered },
    },
    "login-copy": {
      note: "A Release build's one-time consent to copy the person's Claude login to their own machines.",
      props: { start: { ...begun, ask: asks.loginCopy! }, onAnswer: answered },
    },
    "codex-consent": {
      note: "The one-time consent to use this Mac's Codex sign-in for the person's own machines.",
      props: { start: { ...begun, ask: asks.codexConsent! }, onAnswer: answered },
    },
    "codex-device": {
      note: "Codex's device code with Copy; the sign-in page is a link beside I signed in, not a second button.",
      props: { start: { ...begun, ask: asks.codexDevice! }, onAnswer: answered },
    },
    "recover-credentials": {
      note: "A chat's credential recovery in this layout. The host still asks it as a dialog: it is reached from a machine chat's turn, not from a start's card.",
      props: { start: { ...begun, ask: asks.recoverCredentials! }, onAnswer: answered },
    },
    "failed-retry": {
      note: "A start that failed in a way another try can help: the host's words, then Retry (no toast).",
      props: {
        start: {
          ...begun,
          state: "failed",
          retryable: true,
          machine: "paint-dev",
          message: "paint-dev didn't connect in time.",
        },
        onRetry: () => undefined,
      },
    },
  },
  experiment: { definition: cloudStartAskLook, script: [{ name: "Show the question", run: showAsk }] },
});
