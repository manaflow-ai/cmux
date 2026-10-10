// l10n-allow-file: gallery fixtures and labels are public-safe sample data, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { CheckpointReview } from "./Review";
import type { Checkpoint, CheckpointList } from "./protocol";
import { checkpointStrings } from "./strings";

const strings = checkpointStrings();

const base: Checkpoint = {
  checkpoint_id: "checkpoint-a",
  repository_id: "repo-gallery",
  worktree_id: "worktree-gallery",
  ref: "refs/cmux/checkpoints/gallery-a",
  object_id: "abc1234567890",
  revision: "7",
  complete: false,
  skipped: [
    { path: ".env.local", code: "credential_excluded" },
    { path: "dist/bundle.js", code: "too_large" },
  ],
  skipped_total: 2,
  created_at: "2026-10-10T18:20:00Z",
  expires_at: "2026-10-17T18:20:00Z",
  base: { head: "0123456789abcdef", branch: "feat/gallery", detached: false },
  coverage: { included: 12, omitted: 1, unavailable: 1 },
  included: { tracked: 11, untracked: 1, staged_entries: 0 },
  bytes: { logical: 48_320, newly_stored: 12_800 },
  limits: { max_bytes: 10_000_000, max_files: 500, max_untracked_file_bytes: 1_000_000 },
  pins: [],
};

const retained: Checkpoint = {
  ...base,
  checkpoint_id: "checkpoint-retained",
  ref: "refs/cmux/checkpoints/gallery-retained",
  complete: true,
  skipped: [],
  skipped_total: 0,
  pins: [{ pin_id: "user:gallery", reason: "review" }],
};

const list: CheckpointList = {
  repository_id: base.repository_id,
  worktree_id: base.worktree_id,
  checkpoints: [],
  next_cursor: null,
  candidates: [
    { path: "src/agent.ts", bytes: 2_304, eligible: true },
    { path: "src/agent.test.ts", bytes: 1_024, eligible: true },
    { path: ".env.local", bytes: 96, eligible: false, reason: "credential_excluded" },
  ],
  limits: base.limits,
};

type Props = { mode: "create" | "receipt" | "copy-replacement" | "retained" };

const createSelection: Play = async (ctx) => {
  await ctx.click({ role: "checkbox", name: "src/agent.test.ts" });
  await ctx.click({ role: "button", name: strings.create });
  await ctx.waitFor(() => ctx.find({ text: "refs/cmux/checkpoints/gallery-a" }));
};

const keyboardSelection: Play = async (ctx) => {
  await ctx.focus({ role: "checkbox", name: "src/agent.test.ts" });
  await ctx.press("Space");
  await ctx.waitFor(() => {
    const checkbox = ctx.find({ role: "checkbox", name: "src/agent.test.ts" });
    return !(checkbox as HTMLInputElement).checked;
  });
  await ctx.click({ role: "button", name: strings.create });
  await ctx.waitFor(() => ctx.find({ text: "refs/cmux/checkpoints/gallery-a" }));
};

const copyReplacement: Play = async (ctx) => {
  await ctx.click({ role: "button", name: strings.copyReference });
  await ctx.waitFor(() => ctx.find({ text: "refs/cmux/checkpoints/gallery-b" }));
  await ctx.waitFor(() => ctx.find({ role: "button", name: strings.copyReference }));
};

export default componentEntry<Props>({
  id: "agent-pane.checkpoint-review",
  title: "Checkpoint review",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 360, normal: 520, wide: 720 },
  covers: ["agent-session/acpmux/checkpoints/Review.tsx#CheckpointReview"],
  load: async () => {
    function GalleryCheckpointReview({ mode }: Props) {
      const [record, setRecord] = useState<Checkpoint | undefined>(mode === "create" ? undefined : mode === "retained" ? retained : base);
      const next = { ...base, checkpoint_id: "checkpoint-b", ref: "refs/cmux/checkpoints/gallery-b" };
      if (!record) {
        return (
          <CheckpointReview
            list={list}
            strings={strings}
            onCreate={() => setRecord(base)}
            onRefresh={() => undefined}
            onCopy={async () => undefined}
            onKeep={() => undefined}
            onRelease={() => undefined}
            onCancel={() => undefined}
          />
        );
      }
      return (
        <CheckpointReview
          record={record}
          strings={strings}
          onCreate={() => undefined}
          onRefresh={() => undefined}
          onCopy={async () => {
            if (mode === "copy-replacement") setRecord(next);
          }}
          onKeep={() => undefined}
          onRelease={() => undefined}
          onCancel={() => undefined}
        />
      );
    }
    return GalleryCheckpointReview;
  },
  styles: () => import("./styles.css"),
  variants: {
    "create-selection": { props: { mode: "create" }, play: createSelection },
    "keyboard-selection": { props: { mode: "create" }, play: keyboardSelection },
    "partial-receipt": { props: { mode: "receipt" } },
    "copy-replacement": { props: { mode: "copy-replacement" }, play: copyReplacement },
    retained: { props: { mode: "retained" } },
  },
});
