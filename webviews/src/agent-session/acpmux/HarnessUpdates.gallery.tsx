// l10n-allow-file: gallery fixtures exercise the list's shipped labels and update states.
// Harness updates available (Leo 2026-11-12, ask-3fdf0982ec): the model menus' footer listing every
// outdated agent CLI, as a menu panel draws it. The reference listed Codex and OpenCode; here Claude
// Code is the chat's own (its offer: Skip This Version, Restart Chat after) beside the others.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { HarnessUpdatesSection } from "./HarnessUpdates";
import { type HarnessHealth, type UpdateOffer } from "./harnessHealthNoticeModel";
import { useHarnessUpdateList } from "./harnessUpdateList";
import { agentDisplayName } from "./agents";

const row = (id: string, version: string, latest: string, command: string): HarnessHealth => ({
  id,
  version,
  latest,
  outdated: true,
  update: { command, elevated: false },
});
const codex = row("codex", "0.164.0", "0.167.2", "npm install -g @openai/codex@latest");
const opencode = row("opencode", "1.19.0", "1.19.5", "npm install -g opencode-ai@latest");
const CLAUDE = "/Users/me/.local/bin/claude";
const claude = (id: string) => row(id, "2.1.325", "2.1.329", `${CLAUDE} update`);

type Props = {
  /// The chat's own agent's offer (Claude Code), when it has one.
  own?: boolean;
  rows: HarnessHealth[];
  /// How the host's `harness.update` answers: done, failed, or still running.
  updater?: "ok" | "fails" | "pending";
  /// The harnesses the menus offer (default: every one).
  offered?: (id: string) => boolean;
};

function GalleryHarnessUpdates({ own = false, rows, updater = "ok", offered }: Props) {
  const [calls, setCalls] = useState<string[]>([]);
  const offer: UpdateOffer | undefined = own
    ? {
        harness: "claude",
        agent: "Claude Code",
        version: "2.1.30",
        latest: "2.1.34",
        update: () => setCalls((list) => [...list, "offer.update"]),
        skip: () => setCalls((list) => [...list, "offer.skip"]),
      }
    : undefined;
  const updates = useHarnessUpdateList({
    rows,
    offer,
    own: own ? "claude" : undefined,
    nameFor: agentDisplayName,
    native: (method, params) => {
      setCalls((list) => [...list, `${method} ${String(params.id)}`]);
      if (updater === "pending") return new Promise<never>(() => undefined);
      return Promise.resolve(
        updater === "fails" ? { ok: false, error: "npm error code EACCES\nnpm error errno -13" } : { ok: true },
      );
    },
    onUpdated: () => undefined,
    ...(offered ? { offered } : {}),
  });
  return (
    // A menu panel's frame: the footer sits under the model list it belongs to.
    <div className="acpmux-quick-menu ui-menu-popup" data-harness-calls={calls.join(", ")} style={{ width: 360 }}>
      {updates ? <HarnessUpdatesSection updates={updates} /> : <p>No updates</p>}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.harness-updates",
  title: "Harness updates available",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 300, normal: 360, wide: 420 },
  covers: ["agent-session/acpmux/HarnessUpdates.tsx#HarnessUpdatesSection"],
  styles: () => import("./styles.css"),
  load: async () => GalleryHarnessUpdates,
  variants: {
    "three-harnesses": {
      note: "The chat's Claude Code, Codex and OpenCode: a name each, its Update on hover; Update all, the default button, in the heading; versions wait for Option.",
      props: { own: true, rows: [codex, opencode] },
    },
    // David Beyer (Nov 20 call): the versions show only when asked, by holding Option.
    "option-held": {
      note: "Option held: each row adds its installed and newest versions, and the chat's own row Skip This Version.",
      props: { own: true, rows: [codex, opencode] },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        view.dispatchEvent(new view.KeyboardEvent("keydown", { key: "Alt", altKey: true }));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-harness-update-versions") !== null);
      },
    },
    "reference-pair": {
      note: "The reference's pair, Codex and OpenCode, in a chat whose own agent is current.",
      props: { rows: [codex, opencode] },
    },
    // Lawrence 2026-11-19 (clip 3.37.01 PM): "OpenCode" twice.
    "hidden-fallback-and-twin": {
      note: "A harness the menus never offer is left out; opencode-v2 reads OpenCode (v2).",
      props: {
        rows: [
          row("acme", "1.0.0", "1.1.0", "npm install -g acme@latest"),
          opencode,
          row("opencode-v2", "1.18.0", "1.19.6", "npm install -g opencode-ai@latest"),
        ],
        offered: (id) => id !== "acme",
      },
    },
    // Lawrence 2026-11-19 (msg 42278, "there are duplicates sometimes"): acpmux's rows as that Mac had
    // them. `cmux` (the router fallback) runs the same ~/.local/bin/claude as `claude`, and opencode-v2
    // is a 0.0.0-next nightly acpmux no longer calls outdated. No catalog yet: nothing is hidden.
    "one-row-per-binary": {
      note: 'Two profiles of one claude binary are one Claude Code row; never "Cmux", never a nightly.',
      props: {
        rows: [
          { ...claude("claude"), path: CLAUDE, package: "@anthropic-ai/claude-code" },
          { ...claude("cmux"), path: CLAUDE, package: "@anthropic-ai/claude-code" },
          {
            ...row("opencode", "1.19.5", "1.19.6", "bun add -g opencode-ai@latest"),
            path: "/Users/me/.bun/bin/opencode",
          },
          {
            ...row("opencode-v2", "0.0.0-next", "1.19.6", "/Users/me/.opencode/bin/opencode2 upgrade"),
            outdated: false,
          },
        ],
      },
    },
    "one-harness": {
      note: "One outdated agent: one row, no heading; its Update is the default button.",
      props: { rows: [opencode] },
    },
    updating: {
      note: "Update all started: each row's Update is a spinner until the host's updater answers.",
      props: { rows: [codex, opencode], updater: "pending" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-harness-updates-all" });
        await ctx.waitFor(() => ctx.document.querySelectorAll('[data-phase="updating"]').length === 2);
      },
    },
    "update-failed": {
      note: "A failed update is one red line in its name's place (the updater's words go to the log); Try Again on hover.",
      props: { rows: [codex, opencode], updater: "fails" },
      play: async (ctx) => {
        await ctx.click({ selector: '[data-harness-update="codex"] .acpmux-harness-update-run' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-phase="failed"]') !== null);
      },
    },
  },
});
