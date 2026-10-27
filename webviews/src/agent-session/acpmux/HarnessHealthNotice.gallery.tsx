// l10n-allow-file: gallery fixtures exercise the notice's shipped labels and state transitions.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import { HarnessHealthNotice, type HarnessHealth, type UpdateOffer } from "./HarnessHealthNotice";
import { NoticeSlot } from "./NoticeSlot";

/// The started Codex chat the notice sits in.
const codexChat = chat(
  [
    user("Add retries with backoff to the fetch helper", 6),
    assistant("Done: GETs retry, POSTs only with a policy.", 5),
  ],
  { title: "Codex chat", harness: "codex", model: "gpt-5-codex" },
);
const NoChips = () => null;

type Props = {
  health: HarnessHealth;
  /// How the host's updater answers `harness.update`: it finishes, fails, or is still running.
  updater?: "ok" | "fails" | "pending";
  /// A turn is running, so `harness.restart` holds the restart until it ends.
  midTurn?: boolean;
};

function GalleryHarnessHealthNotice({ health, updater = "ok", midTurn = false }: Props) {
  const [opened, setOpened] = useState<string>();
  const [calls, setCalls] = useState<string[]>([]);
  const [offer, setOffer] = useState<UpdateOffer>();
  const native = (method: string) => {
    setCalls((list) => [...list, method]);
    if (method === "harness.restart")
      return Promise.resolve(midTurn ? { restarted: 0, after_turn: 1 } : { restarted: 1, after_turn: 0 });
    if (updater === "pending") return new Promise<never>(() => undefined);
    return Promise.resolve(
      updater === "fails" ? { ok: false, error: "npm exited with status 1" } : { ok: true, version: health.latest },
    );
  };
  return (
    // The pane's own frame (App.tsx): the stage, then the bottom stack in the pane's flow with the
    // notice slot over the real composer, so a notice that draws nothing still shows the composer
    // it leaves. The stage gives up the notice's height; the composer keeps its place.
    <section
      className="acpmux-shell harness-health-gallery"
      aria-label={codexChat.summary?.title}
      data-harness-opened={opened ? "true" : "false"}
      data-harness-command={opened}
      data-harness-calls={calls.join(" ")}
    >
      <div className="acpmux-main">
        <div className="acpmux-stage">
          {/* The model chip's update row stands in here: the offer is never a line over the chat,
            so it sits in the stage, out of the bottom stack. */}
          {offer && (
            <div className="harness-health-gallery-offer" data-harness-offer={offer.latest}>
              <button type="button" data-notice-action="update" onClick={offer.update}>
                Update
              </button>
              <button type="button" data-notice-action="skip" onClick={offer.skip}>
                Skip This Version
              </button>
            </div>
          )}
        </div>
        <div className="acpmux-dock">
          <NoticeSlot>
            <HarnessHealthNotice
              health={health}
              harness={health.id}
              name="Codex"
              cwd="/Users/you/src/cmux"
              open={({ text }) => setOpened(text)}
              native={native}
              turnRunning={midTurn}
              onOffer={setOffer}
            />
          </NoticeSlot>
          <Composer snapshot={codexChat} chips={NoChips} onSend={() => true} onStop={() => undefined} />
        </div>
      </div>
    </section>
  );
}

const phase = (ctx: Parameters<Play>[0], name: string) =>
  ctx.document.querySelector(`[data-harness-phase="${name}"]`) !== null;

const runLogin: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-action="login"]' });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-harness-opened="true"]')?.getAttribute("data-harness-command") ===
      "codex login",
  );
};

const runUpdate: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-action="update"]' });
  await ctx.waitFor(() => phase(ctx, "updated"));
};

const runUpdating: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-action="update"]' });
  await ctx.waitFor(() => phase(ctx, "updating"));
};

const runFailed: Play = async (ctx) => {
  await ctx.click({ selector: '[data-notice-action="update"]' });
  await ctx.waitFor(() => phase(ctx, "failed"));
};

const runRestartAfterTurn: Play = async (ctx) => {
  await runUpdate(ctx);
  await ctx.click({ selector: '[data-notice-action="restart"]' });
  await ctx.waitFor(() => phase(ctx, "waiting"));
};

const dismiss: Play = async (ctx) => {
  await runUpdate(ctx);
  await ctx.click({ selector: '[data-notice-action="dismiss"]' });
  await ctx.waitFor(() => ctx.document.querySelector("[data-harness-notice]") === null);
  if (!ctx.document.querySelector(".acpmux-composer")) throw new Error("dismissing the notice removed the composer");
};

const signedOut: HarnessHealth = { id: "codex", auth: "signedOut", login: "codex login" };
const unknownWithRecovery: HarnessHealth = { id: "codex", auth: "unknown", login: "codex login" };
const outdated: HarnessHealth = {
  id: "codex",
  auth: "signedIn",
  version: "0.3.1",
  latest: "0.4.0",
  outdated: true,
  update: { command: "npm install -g @openai/codex@latest", elevated: false },
};

export default componentEntry<Props>({
  id: "agent-pane.harness-health-notice",
  title: "Agent CLI health notice",
  area: "Agent pane",
  pane: true,
  height: 280,
  widths: { narrow: 360, normal: 560, wide: 760 },
  // The composer, not the notice: Not Now removes the notice, and the composer under it must stay put.
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/HarnessHealthNotice.tsx#HarnessHealthNotice"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason:
        "Running an agent login, an in-place update or Not Now must leave the composer under the notice in place.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Dismissal and command handoff change notice state without adding document flow around the composer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "The notice actions are local state changes and should remain responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Login, update, and dismissal feedback should settle within a quarter second.",
    },
  },
  load: async () => GalleryHarnessHealthNotice,
  variants: {
    "signed-out": {
      note: "A signed-out Codex CLI says so inline and offers Log In in the chat's folder.",
      props: { health: signedOut },
      play: runLogin,
    },
    "unknown-with-recovery": {
      note: "When the daemon cannot inspect a keychain login, offer the known sign-in command before the first prompt.",
      props: { health: unknownWithRecovery },
      play: runLogin,
    },
    outdated: {
      note: "An outdated Codex CLI draws no line here; the model chip offers Update and Skip This Version (stand-in below).",
      props: { health: outdated },
    },
    updating: {
      note: "Update runs the host's updater in place; the line says so quietly while it works.",
      props: { health: outdated, updater: "pending" },
      play: runUpdating,
    },
    updated: {
      note: "A finished update says the new version is installed and offers Restart Chat.",
      props: { health: outdated },
      play: runUpdate,
    },
    "restart-after-turn": {
      note: "A chat mid-turn restarts on the new version when the turn ends; the card says so.",
      props: { health: outdated, midTurn: true },
      play: runRestartAfterTurn,
    },
    "update-failed": {
      note: "A failed update shows the updater's error inline with Try Again and Not Now.",
      props: { health: outdated, updater: "fails" },
      play: runFailed,
    },
    dismissed: {
      note: "Not Now hides the finished update's line for this chat while leaving the composer in place.",
      props: { health: outdated },
      play: dismiss,
    },
    "sudo-update": {
      note: "Updates that require elevation stay out of the pane; Settings owns that action.",
      props: {
        health: {
          ...outdated,
          update: { command: "sudo npm install -g @openai/codex@latest", elevated: true },
        },
      },
    },
  },
});
