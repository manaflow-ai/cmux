// l10n-allow-file: gallery fixtures exercise the notice's shipped labels and state transitions.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { HarnessHealthNotice, type HarnessHealth } from "./HarnessHealthNotice";

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
    <div
      className="harness-health-gallery"
      data-harness-opened={opened ? "true" : "false"}
      data-harness-command={opened}
      data-harness-calls={calls.join(" ")}
    >
      <HarnessHealthNotice
        health={health}
        harness={health.id}
        name="Codex"
        cwd="/Users/you/src/cmux"
        open={({ text }) => setOpened(text)}
        native={native}
        turnRunning={midTurn}
      />
    </div>
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
  await ctx.click({ selector: '[data-notice-action="dismiss"]' });
  await ctx.waitFor(() => ctx.document.querySelector("[data-harness-notice]") === null);
};

const signedOut: HarnessHealth = { id: "codex", auth: "signedOut", login: "codex login" };
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
  height: 150,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-harness-notice" }],
  covers: ["agent-session/acpmux/HarnessHealthNotice.tsx#HarnessHealthNotice"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Running an agent login or an in-place update must leave the inline notice anchored above the composer.",
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
    outdated: {
      note: "An outdated Codex CLI offers Update, Skip This Version and Not Now without hiding the current chat.",
      props: { health: outdated },
    },
    updating: {
      note: "Update runs the host's updater in place; the card says so quietly and holds Update and Skip.",
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
      note: "Not Now hides the notice for this chat while leaving the composer in place.",
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
