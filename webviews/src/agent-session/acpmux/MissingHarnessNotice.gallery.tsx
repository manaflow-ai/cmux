// l10n-allow-file: gallery fixtures exercise the notice's shipped labels and state transitions.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { chat } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import type { SetupPhase } from "./harnessSetup";
import { MissingHarnessNotice } from "./MissingHarnessNotice";
import { NoticeSlot } from "./NoticeSlot";

/// A fresh Mac's first chat: nothing sent yet, the typed message back in the composer.
const fresh = chat([], { title: "New chat", harness: "claude", model: "default" });
const NoChips = () => null;

type Props = {
  /// The install's step, when one runs.
  phase?: SetupPhase;
  /// Codex is on this Mac: Use Codex Instead shows.
  codex?: boolean;
  /// cmux has no installer for the agent (Gemini CLI): Set Up opens the agents page.
  installable?: boolean;
  name?: string;
  /// The shipped card, or one of the looks it was chosen over.
  look?: "card" | "row" | "quiet";
};

function GalleryMissingHarness({
  phase,
  codex = false,
  installable = true,
  name = "Claude Code",
  look = "card",
}: Props) {
  const [clicked, setClicked] = useState<string>();
  return (
    <section
      className="acpmux-shell missing-harness-gallery"
      aria-label="Missing agent"
      data-look={look}
      data-missing-clicked={clicked ?? ""}
    >
      <div className="acpmux-main">
        <div className="acpmux-stage" />
        <div className="acpmux-dock">
          <NoticeSlot>
            <MissingHarnessNotice
              name={name}
              {...(phase ? { phase } : {})}
              installable={installable}
              {...(codex ? { alternative: "Codex", onUseInstead: () => setClicked("instead") } : {})}
              onInstall={() => setClicked("install")}
              onSignIn={() => setClicked("signIn")}
              onSetUp={() => setClicked("setUp")}
            />
          </NoticeSlot>
          <Composer snapshot={fresh} chips={NoChips} onSend={() => true} onStop={() => undefined} />
        </div>
      </div>
    </section>
  );
}

const clickInstall: Play = async (ctx) => {
  await ctx.click({ selector: '[data-missing-action="install"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-missing-clicked="install"]') !== null);
};

export default componentEntry<Props>({
  id: "agent-pane.missing-harness-notice",
  title: "Agent not installed notice",
  area: "Agent pane",
  pane: true,
  height: 240,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/MissingHarnessNotice.tsx#MissingHarnessNotice"],
  styles: () => Promise.all([import("./styles.css"), import("./MissingHarnessNotice.gallery.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Install, its progress and its sign-in change the notice's words, never the composer's place.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The notice's steps swap text and buttons in one card; nothing around the composer moves.",
    },
  },
  load: async () => GalleryMissingHarness,
  variants: {
    // Chosen: the same neutral card the sign-in and update notices use in this slot, so the
    // composer's notices read as one family; its buttons wrap under the line at any width.
    "look-card": {
      note: "Shipped look. One line and Install on the composer's notice card, as Log In and Update are.",
      props: { look: "card" },
      play: clickInstall,
    },
    "look-row": {
      note: "Candidate: the line and Install on one row. Wraps awkwardly in a narrow pane once Use Codex Instead joins.",
      props: { look: "row", codex: true },
    },
    "look-quiet": {
      note: "Candidate: no card, link-style Install. Too easy to miss for the one thing the person must do.",
      props: { look: "quiet" },
    },
    "with-codex": {
      note: "Codex is installed: Use Codex Instead starts the chat there with the typed message.",
      props: { codex: true },
    },
    installing: {
      note: "Install runs the official installer in place; the line says so with its last output line under it.",
      props: { phase: { kind: "installing", line: "Downloading Claude Code 2.4.1 (macOS arm64)..." } },
    },
    "sign-in": {
      note: "Installed but signed out: Sign In opens its login, then the chat starts with the typed message.",
      props: { phase: { kind: "signIn" } },
    },
    starting: {
      note: "Ready: the chat starts and the typed message goes.",
      props: { phase: { kind: "ready" } },
    },
    failed: {
      note: "The installer failed: one line, Try Again (and Use Codex Instead); its own words under Details.",
      props: { phase: { kind: "failed", reason: "curl: (6) Could not resolve host: claude.ai" }, codex: true },
    },
    "no-installer": {
      note: "An agent cmux cannot install itself: Set Up opens the agents page.",
      props: { name: "Gemini CLI", installable: false },
    },
  },
});
