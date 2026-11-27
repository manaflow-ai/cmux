// l10n-allow-file: gallery fixtures, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { type CloudSignIn, type LoginAgent, LoginStepError } from "./cloudAgentLogin";
import { ErrorDetails } from "./conversation/ErrorDetails";
import { useT } from "./i18n";
import { NativeError } from "./nativeError";
import { startFailureClearsByItself, startFailureView } from "./startFailure";
import { SwitchNotice } from "./SwitchNotice";

/// `share`: how the fixture's Share with Me answers (a team admin's share, or the creator-or-admin refusal).
/// `harness`/`name`: the agent that did not start (Claude Code unless named). `signIn`: how a sign-in
/// refusal's Sign in runs here: the machine's own card (a chat elsewhere whose acpmux signs it in),
/// a terminal login (a chat on this Mac), or none (a chat elsewhere with no sign-in for it).
/// `alternative`: a design not shipped, kept to compare (hq#11225).
type Props = {
  error: string;
  code?: string;
  share?: "shared" | "forbidden";
  harness?: LoginAgent | "pi" | "cmux";
  name?: string;
  /// `localCard`: a chat on this Mac whose daemon runs the agent's login (logins done right): the card.
  signIn?: "card" | "localCard" | "terminal" | "none";
  signInExpired?: true;
  /// A chat on another machine (a Cloud machine): never Install, which runs on this Mac.
  elsewhere?: true;
  alternative?: "compact" | "two-step" | "route-interim" | "route-hint";
};

/// Not shipped, for the cmux router's route refusal (hq#11225): the interim words "doesn't run on Cloud
/// machines yet", or the shipped sentence with a "pick another agent" line under it. Both beside Retry, the
/// host's words under Details, as the shipped card has them.
function RouteAlternative({ alternative, error }: { alternative: "route-interim" | "route-hint"; error: string }) {
  const t = useT();
  const sentence =
    alternative === "route-interim"
      ? "The cmux router doesn't run on Cloud machines yet."
      : t("switch.routerUnavailable");
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{sentence}</p>
        {alternative === "route-hint" && (
          <p className="acpmux-host-error-hint">Pick another agent for this chat, or Retry later.</p>
        )}
        <div className="acpmux-host-error-actions">
          <button type="button">{t("switch.retry")}</button>
        </div>
        <ErrorDetails text={error} className="acpmux-host-error-details" />
      </div>
    </div>
  );
}

/// The machine's sign-in for the gallery: a page and a code (Grok), a page (Cursor), a key (Gemini).
/// Nothing leaves the gallery.
function gallerySignIn(agent: LoginAgent): CloudSignIn {
  return {
    agent,
    start: async () => {
      if (agent === "gemini") throw new LoginStepError("unsupported");
      if (agent === "codex")
        return {
          loginId: "gallery",
          url: "https://auth.openai.com/codex/device",
          userCode: "K7QX-29PF",
          needsCode: false,
        };
      if (agent === "grok")
        return { loginId: "gallery", url: "https://accounts.x.ai/device", userCode: "WDJB-MJHT", needsCode: false };
      return { loginId: "gallery", url: "https://cursor.com/loginDeepControl?challenge=gallery", needsCode: false };
    },
    open: () => {},
    openOnMachine: async () => true,
    finish: () => new Promise<boolean>(() => {}),
    apiKey: async () => true,
    gateway: async () => true,
    cancel: () => {},
    reserve: async () => undefined,
    resend: async () => {},
  };
}

/// Not shipped: one muted line with Sign in as a link and the agent's words under Details. Quiet,
/// but the cause and its fix share a line that wraps at narrow widths, and Retry is gone.
function CompactAlternative({ name, error }: { name: string; error: string }) {
  const t = useT();
  const view = startFailureView(t, { harness: "cursor", name, error, code: "agent_session.sign_in_required" });
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">
          {view.sentence}{" "}
          <button type="button" className="cv-turn-error__offer-link">
            {t("picker.signInTo", { harness: name })}
          </button>
        </p>
        {view.detail && <ErrorDetails text={view.detail} className="acpmux-host-error-details" />}
      </div>
    </div>
  );
}

function GallerySwitchNotice({
  error,
  code,
  share,
  harness,
  name,
  signIn,
  signInExpired,
  elsewhere: away,
  alternative,
}: Props) {
  const [ran, setRan] = useState<string>();
  const [opened, setOpened] = useState(false);
  const agent = name ?? "Claude Code";
  if (alternative === "compact")
    return (
      <div className="acpmux-shell" data-switch-notice-fixture>
        <CompactAlternative name={agent} error={error} />
      </div>
    );
  if (alternative === "route-interim" || alternative === "route-hint")
    return (
      <div className="acpmux-shell" data-switch-notice-fixture>
        <RouteAlternative alternative={alternative} error={error} />
      </div>
    );
  // Not shipped: Sign in first, and only its click shows the machine's sign-in card (two clicks to the
  // provider's page where the shipped card takes one).
  const twoStep = alternative === "two-step" && !opened;
  const elsewhere = away === true || signIn === "card" || signIn === "none";
  return (
    <div className="acpmux-shell" data-switch-notice-fixture data-ran={ran}>
      <SwitchNotice
        switching={{
          harness: harness ?? "claude",
          name: agent,
          phase: "failed",
          error,
          ...(code && { code }),
          ...(signInExpired && { signInExpired }),
        }}
        // A start that only lost the line to acpmux is started again by the pane (App.tsx useAutoRetry).
        stillTrying={startFailureClearsByItself(code)}
        onRetry={() => setRan("retry")}
        onAction={(action) => {
          setRan(action);
          if (twoStep) setOpened(true);
        }}
        installs={!elsewhere || twoStep}
        runsLogin={signIn === "terminal" || signIn === "localCard" || twoStep}
        {...((signIn === "card" || signIn === "localCard") &&
          harness &&
          !twoStep && { agentSignIn: gallerySignIn(harness as LoginAgent) })}
        {...(share && {
          share: {
            machine: "build-box",
            call: async () => {
              if (share === "forbidden") throw new NativeError({ code: "machine.creator_or_admin" });
              return { shared: true };
            },
          },
        })}
      />
    </div>
  );
}

const newMachine: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "New Cloud Machine" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Retry" }) !== null);
};

const shareRefused: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Share with Me" });
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Ask the Owner" }) !== null);
};

/// The agents' own words for a missing sign-in (cmux-tui acpmux recovery.rs `start_sign_in`).
const CURSOR_WORDS = "Authentication required";
const GEMINI_WORDS = "API key missing";
const GROK_WORDS = "agent process closed (grok): Authentication required";
const SIGN_IN = "agent_session.sign_in_required";
/// The Mac's own words for the two refusals on a Cloud machine (AgentRemoteStartRefusal.swift), which
/// the card keeps under Details (hq#11225).
const HARNESS_MISSING = "agent_session.harness_missing";
const ROUTE_UNAVAILABLE = "agent_session.route_unavailable";
const PI_MISSING_WORDS =
  "Pi isn't installed on devbox-3. Install it there or pick another agent, then start the chat again.";
const ROUTER_WORDS = "The cmux router isn't available on devbox-3. Pick another agent, or start the chat again later.";

export default componentEntry<Props>({
  id: "agent-pane.switch-notice",
  title: "Agent start refused",
  area: "Agent pane",
  height: 160,
  widths: { narrow: 360, normal: 520, wide: 720 },
  anchors: [{ selector: "[data-switch-notice-fixture]" }],
  covers: ["agent-session/acpmux/SwitchNotice.tsx#SwitchNotice"],
  styles: () => Promise.all([import("./styles.css"), import("./conversation/conversation.css")]).then(() => undefined),
  load: async () => GallerySwitchNotice,
  variants: {
    "teammate-machine": {
      props: {
        error:
          "build-box is a teammate's machine, so its owner starts chats there. Pick your own machine, or create one with New Cloud Machine.",
        code: "agent_session.team_vm_blocked",
        share: "shared",
      },
      play: newMachine,
      note: "A teammate's machine: Share with Me (a team admin's share retries the start), then the person's own new machine, beside Retry.",
    },
    "teammate-machine-share-refused": {
      props: {
        error:
          "build-box is a teammate's machine, so its owner starts chats there. Pick your own machine, or create one with New Cloud Machine.",
        code: "agent_session.team_vm_blocked",
        share: "forbidden",
      },
      play: shareRefused,
      note: "Share with Me refused (only the creator or a team admin shares): the same button becomes Ask the Owner, which copies a request naming the machine.",
    },
    "no-folder": {
      props: {
        error: "build-box has no work folder to start in. Use Choose folder to pick one there.",
        code: "app.folder_needed",
      },
      note: "No folder and no work folder on the machine (an older cmux-tui): Choose Folder… beside Retry.",
    },
    "sign-in-cursor-cloud": {
      props: { error: CURSOR_WORDS, code: SIGN_IN, harness: "cursor", name: "Cursor", signIn: "card" },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Sign in to Cursor" });
      },
      note: "Shipped (hq#11225). Cursor not signed in on a Cloud machine: the cause by name, the machine's own sign-in card leading (Sign in to Cursor opens its page there), Retry beside it, the agent's words under Details.",
    },
    "sign-in-grok-cloud": {
      props: { error: GROK_WORDS, code: SIGN_IN, harness: "grok", name: "Grok", signIn: "card" },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Sign in to Grok" });
        await ctx.waitFor(() => ctx.find({ selector: "[data-testid=cloud-signin-code]" }) !== null);
      },
      note: "Shipped. Grok's device sign-in in the card: its code to enter on the page, then Retry starts Grok signed in.",
    },
    "sign-in-gemini-cloud": {
      props: { error: GEMINI_WORDS, code: SIGN_IN, harness: "gemini", name: "Gemini CLI", signIn: "card" },
      note: "Shipped. Gemini takes a key only: Use an API key is the card's one sign-in button.",
    },
    "sign-in-cursor-expired": {
      props: {
        error: CURSOR_WORDS,
        code: SIGN_IN,
        harness: "cursor",
        name: "Cursor",
        signIn: "card",
        signInExpired: true,
      },
      note: "Shipped. An expired sign-in says it expired, with the same sign-in.",
    },
    "sign-in-cursor-this-mac": {
      props: { error: CURSOR_WORDS, code: SIGN_IN, harness: "cursor", name: "Cursor", signIn: "terminal" },
      note: "Shipped. A chat on this Mac: Sign in to Cursor runs its login in a terminal tab, as the sign-in notice does; then Retry.",
    },
    "sign-in-codex-this-mac-in-place": {
      props: { error: CURSOR_WORDS, code: SIGN_IN, harness: "codex", name: "Codex", signIn: "localCard" },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Sign in to Codex" });
        await ctx.waitFor(() => ctx.find({ selector: "[data-testid=cloud-signin-code]" }) !== null);
      },
      note: 'Logins done right (Leo, 2026-11-22: "this is simply logins, done righr."): a chat on this Mac whose daemon runs Codex\'s login signs in with the card, as a Cloud chat does; no terminal tab. An older daemon keeps sign-in-cursor-this-mac.',
    },
    "sign-in-cursor-no-machine-sign-in": {
      props: { error: CURSOR_WORDS, code: SIGN_IN, harness: "cursor", name: "Cursor", signIn: "none" },
      note: "Shipped. A machine with no sign-in for the agent (a new chat with no session there yet, an older cmux): the cause, where to sign in, and Retry. Never a login on this Mac.",
    },
    "sign-in-alternative-compact": {
      props: { error: CURSOR_WORDS, harness: "cursor", name: "Cursor", alternative: "compact" },
      note: "Alternative, not shipped: one line with Sign in as a link. Rejected: no Retry after signing in, and the link wraps under the sentence at narrow widths.",
    },
    "sign-in-alternative-two-step": {
      props: {
        error: CURSOR_WORDS,
        code: SIGN_IN,
        harness: "cursor",
        name: "Cursor",
        signIn: "card",
        alternative: "two-step",
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Sign in to Cursor" });
      },
      note: "Alternative, not shipped: a plain Sign in button that only then shows the machine's sign-in card. Rejected: two clicks to the provider's page where the shipped card takes one.",
    },
    "harness-missing-pi-cloud": {
      props: { error: PI_MISSING_WORDS, code: HARNESS_MISSING, harness: "pi", name: "Pi", elsewhere: true },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-switch-failed summary" });
      },
      note: "Shipped (hq#11225). An agent the Cloud machine doesn't have (Pi without its adapter): the agent by name, Retry, and the host's words under Details. No Install: the installer runs on this Mac, not there.",
    },
    "harness-missing-this-mac": {
      props: {
        error: "Gemini CLI isn't in this machine's agent catalog.",
        code: HARNESS_MISSING,
        harness: "gemini",
        name: "Gemini CLI",
      },
      note: "Shipped. The same refusal for a chat on this Mac: Install runs the agent's installer in a terminal tab, as a spawn that found no CLI does.",
    },
    "route-unavailable-cmux-router-cloud": {
      props: { error: ROUTER_WORDS, code: ROUTE_UNAVAILABLE, harness: "cmux", name: "cmux", elsewhere: true },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-switch-failed summary" });
      },
      note: "Shipped (hq#11225). The cmux router on a Cloud machine with no router to serve it: names the router, Retry, the host's words under Details. Stays true once the router runs on Cloud: the refusal comes only while the route truly can't serve the start.",
    },
    "route-unavailable-named-agent": {
      props: {
        error:
          "Claude Code's model route isn't available on devbox-3. Pick another agent, or start the chat again later.",
        code: ROUTE_UNAVAILABLE,
        harness: "claude",
        elsewhere: true,
      },
      note: "Shipped. Any other agent whose profile's route can't serve it there: the agent's route by name.",
    },
    "route-unavailable-alternative-interim": {
      props: { error: ROUTER_WORDS, alternative: "route-interim" },
      note: 'Alternative, not shipped: "The cmux router doesn\'t run on Cloud machines yet." Rejected: wrong as soon as the router runs on Cloud through the gateway, while the refusal can still come for an outage.',
    },
    "route-unavailable-alternative-hint": {
      props: { error: ROUTER_WORDS, alternative: "route-hint" },
      note: "Alternative, not shipped: the shipped sentence plus a 'pick another agent' line. Rejected: a second line that repeats what Retry and the composer's agent picker already offer, and the card grows a row.",
    },
    "service-unreachable-still-trying": {
      props: { error: "The connection to acpmux closed.", code: "transport.closed" },
      note: "A start that never reached the agent because the line to acpmux dropped: the pane starts it again on its own, with no card and no Retry (Leo, 2026-11-22). Only past 25 s, this one quiet line.",
    },
    plain: {
      props: { error: "build-box did not start the agent in time. Try again." },
      note: "A refusal with no way out but trying again: Retry only, as before.",
    },
    "not-installed": {
      props: { error: "spawn claude-agent-acp: No such file or directory (os error 2)" },
      note: "The agent is not on the machine: says so in plain words, Install runs its installer in a terminal tab, and the spawn error waits under Details.",
    },
    unreachable: {
      props: { error: "acpmux: connect ECONNREFUSED 127.0.0.1:443 (os error 61)" },
      note: "A start that could not reach the model's server reads as a failed turn does, never the socket error.",
    },
    "unknown-details-open": {
      props: { error: "acp handshake: unexpected frame 0x1f in initialize (expected jsonrpc 2.0)" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-switch-failed summary" });
      },
      note: "An unknown start failure: a plain sentence, and Details open on the raw words with Copy error.",
    },
  },
});
