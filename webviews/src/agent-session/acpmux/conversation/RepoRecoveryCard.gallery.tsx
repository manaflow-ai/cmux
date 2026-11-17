// l10n-allow-file: gallery-only recovery fixtures and the rejected alternatives' copy.
import { componentEntry } from "../../../gallery/format";
import { RepoRecoveryCard, RepoRecoveryCardView } from "./RepoRecoveryCard";
import {
  repoRecoveryView,
  type RepoRecovery,
  type RepoRecoveryPhase,
  type RepoRecoveryView,
} from "./repoRecoveryCardModel";

/// `phase`: the card as it ships, started in that phase. `alt`: a rejected alternative, drawn with
/// the same component and classes so the comparison is fair. `outcomes`: the shipped later lines.
type Props = { recovery: RepoRecovery; phase?: RepoRecoveryPhase; alt?: RepoRecoveryView; outcomes?: boolean };

const retry = {
  action: "cloud.repo.add",
  args: { session: "cloud-demo", repo: "acme/cmux-platform" },
  wait_action: "cloud.repo.wait_github",
};
const needsGithub: RepoRecovery = {
  code: "repo.needs_github",
  installUrl: "https://github.com/apps/cmux/installations/new",
  retry,
};
const needsGithubNoUrl: RepoRecovery = { code: "repo.needs_github", retry };
const noAccess: RepoRecovery = {
  code: "repo.no_access",
  org: "acme",
  installUrl: "https://github.com/apps/cmux/installations/new",
};
const ambiguous: RepoRecovery = {
  code: "repo.ambiguous",
  choices: [
    { fullName: "acme/cmux-platform", private: true, source: "recent" },
    { fullName: "manaflow-ai/cmux-platform", source: "installation" },
  ],
  retry: { action: "cloud.repo.add", args: { session: "cloud-demo", repo: "cmux-platform" } },
};

/** A countdown 45 s from the capture, as a wait a quarter of the way through. */
const soon = () => Date.now() + 45_000;
const literal = (text: string) => ({ literal: text });
const checkAgain = { id: "checkAgain" as const, label: { key: "cloudRepository.checkAgain" as const } };
const reopen = { id: "reopen" as const, label: { key: "cloudRepository.openGithubAgain" as const } };
const tryAgain = { id: "retry" as const, label: { key: "cloudRepository.tryAgain" as const } };
const getLink = { id: "getLink" as const, label: { key: "cloudRepository.tryAgain" as const } };
const connect = { id: "connect" as const, label: { key: "cloudRepository.connect" as const } };

export default componentEntry<Props>({
  id: "agent-pane.repo-recovery",
  title: "Cloud repository recovery",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 360, normal: 560, wide: 720 },
  covers: ["agent-session/acpmux/conversation/RepoRecoveryCard.tsx#RepoRecoveryCard"],
  styles: () => import("./conversation.css"),
  load: async () =>
    function RepoRecoveryGallery({ recovery, phase, alt, outcomes }: Props) {
      const lines = (phases: RepoRecoveryPhase[]) =>
        phases.map((item) => {
          const view = repoRecoveryView(recovery, item);
          return view && <RepoRecoveryCardView key={item.kind} view={view} />;
        });
      return (
        <div style={{ padding: "24px", display: "grid", gap: 8 }}>
          {alt ? <RepoRecoveryCardView view={alt} /> : <RepoRecoveryCard recovery={recovery} initialPhase={phase} />}
          {/* The card's later lines (it reaches them by clicking): the same column, the shared inks. */}
          {outcomes &&
            lines([
              { kind: "waiting", until: soon() },
              { kind: "notConnected" },
              { kind: "retrying" },
              { kind: "done", connected: true },
              { kind: "failed" },
            ])}
        </div>
      );
    },
  variants: {
    "needs-github": {
      note: "Picked: the gap in task terms (GitHub, so the cloud machine can clone the named repository) and one Connect step.",
      props: { recovery: needsGithub },
    },
    "needs-github-alt-old": {
      note: "Rejected (before): Connecting GitHub… before anything connects, which reads as already waiting.",
      props: {
        recovery: needsGithub,
        alt: { tone: "quiet", message: literal("Connecting GitHub…"), actions: [connect] },
      },
    },
    "needs-github-alt-terse": {
      note: "Rejected: GitHub access needed, which doesn't say what the access is for.",
      props: {
        recovery: needsGithub,
        alt: { tone: "plain", message: literal("GitHub access needed"), actions: [connect] },
      },
    },
    "needs-github-no-link": {
      note: "Picked: no install link in the error. Connect still shows; it asks the app for the link the repository picker uses, then opens it and waits.",
      props: { recovery: needsGithubNoUrl },
    },
    "no-link": {
      note: "Picked: the app had no link either. Try again asks again; Check again catches a GitHub connected some other way.",
      props: { recovery: needsGithubNoUrl, phase: { kind: "noLink" } },
    },
    "no-link-alt-retry-only": {
      note: "Rejected: Try again alone. A person who already connected on github.com has no way to say so.",
      props: {
        recovery: needsGithubNoUrl,
        alt: { tone: "error", message: literal("Couldn’t get a GitHub connect link"), actions: [getLink] },
      },
    },
    "no-link-alt-pointer": {
      note: "Rejected: points at Session Info's Add repository… instead of acting; a trip out of the conversation.",
      props: {
        recovery: needsGithubNoUrl,
        alt: {
          tone: "error",
          message: literal("Couldn’t get a GitHub connect link. Use Add repository… in Session Info."),
          actions: [],
        },
      },
    },
    waiting: {
      note: "Picked: what it waits for and a live m:ss countdown to the host's one-minute check, with the install page one click away if it closed.",
      props: { recovery: needsGithub, phase: { kind: "waiting", until: soon() } },
    },
    "waiting-alt-ceiling": {
      note: "Rejected: a fixed up-to-1-min ceiling. True, but it doesn't move, so the wait looks stuck.",
      props: {
        recovery: needsGithub,
        alt: {
          tone: "quiet",
          message: literal("Waiting for the GitHub install to finish (up to 1 min)"),
          actions: [reopen],
        },
      },
    },
    "waiting-alt-bare": {
      note: "Rejected: reason and countdown but no way back to a closed install page.",
      props: {
        recovery: needsGithub,
        alt: { tone: "quiet", message: { key: "cloudRepository.waitingGithub" }, actions: [], until: soon() },
      },
    },
    "not-connected": {
      note: "Picked: the connect didn't take. Says so, in the failure ink, with Check again first and the install page again.",
      props: { recovery: needsGithub, phase: { kind: "notConnected" } },
    },
    "not-connected-alt-check-only": {
      note: "Rejected: Check again alone. A person who closed the install page must find it again.",
      props: {
        recovery: needsGithub,
        alt: { tone: "error", message: { key: "cloudRepository.notConnectedYet" }, actions: [checkAgain] },
      },
    },
    "not-connected-alt-instruction": {
      note: "Rejected: a sentence of instructions in front of the button; longer to read, same one click.",
      props: {
        recovery: needsGithub,
        alt: {
          tone: "error",
          message: literal("GitHub isn’t connected yet. Finish the install on GitHub, then check again."),
          actions: [checkAgain],
        },
      },
    },
    failed: {
      note: "Picked: names the repository and offers Try again.",
      props: { recovery: needsGithub, phase: { kind: "failed" } },
    },
    "failed-alt-old-copy": {
      note: "Rejected: the earlier copy with a button added; 'this repository action' doesn't say which.",
      props: {
        recovery: needsGithub,
        alt: { tone: "error", message: literal("Couldn’t recover this repository action"), actions: [tryAgain] },
      },
    },
    "failed-alt-reconnect": {
      note: "Rejected: Try again plus Connect GitHub. GitHub was already verified on the way here, so a second connect is noise.",
      props: {
        recovery: needsGithub,
        alt: {
          tone: "error",
          message: { key: "cloudRepository.attachFailedRepo", values: { target: literal("acme/cmux-platform") } },
          actions: [tryAgain, connect],
        },
      },
    },
    done: {
      note: "Picked: the verified end, a success chip with its check: GitHub connected · the repository attached.",
      props: { recovery: needsGithub, phase: { kind: "done", connected: true } },
    },
    "done-alt-plain": {
      note: "Rejected: the same words as plain success-ink text with a check; it doesn't read as the close of the request.",
      props: {
        recovery: needsGithub,
        alt: { tone: "quiet", message: literal("✓ GitHub connected · acme/cmux-platform attached"), actions: [] },
      },
    },
    "done-alt-short": {
      note: "Rejected: a bare Connected ✓ chip; it drops which repository is now on the machine.",
      props: {
        recovery: needsGithub,
        alt: { tone: "done", message: literal("Connected"), actions: [] },
      },
    },
    "no-access": { note: "The organization is named with install and request actions.", props: { recovery: noAccess } },
    ambiguous: { note: "Several matching repositories are one tap away.", props: { recovery: ambiguous } },
    outcomes: {
      note: "Its later lines on the tool row's text column: waiting with its countdown, not connected with Check again, attaching, the connected chip, and failed with Try again.",
      height: 320,
      props: { recovery: needsGithub, outcomes: true },
    },
  },
});
