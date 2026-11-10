// l10n-allow-file: synthetic exploratory gallery fixture, not live UI strings.
// Gallery-only prototype in the actual Session Info panel. Existing Changes/Artifacts navigation is
// represented by explicit host callback stubs; this does not claim a signed runtime, network owner
// fetch, active permission, or test of the production app.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { SessionInfoPanel } from "./SessionInfo";
import { ReturnBrief } from "./ReturnBrief";
import type { ReturnBriefInput } from "./returnBriefModel";

type Props = { caseName: "complete" | "transcript" | "wrong-team" | "stale" | "unknown" };
const COMMIT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const REVISION = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const DIGEST = "sha256:" + "c".repeat(64);
const NOW = 1_800_000;
const base: ReturnBriefInput = {
  sessionId: "session-synthetic-17",
  turnId: "turn-4",
  repository: "example/atlas",
  commit: COMMIT,
  now: NOW,
  viewerScope: "team-alpha",
  observed: { changedPaths: ["src/net/retry.ts", "test/retry.test.ts"], previews: 1 },
  run: {
    ownerRead: true,
    sessionId: "session-synthetic-17",
    turnId: "turn-4",
    commit: COMMIT,
    kind: "tests",
    state: "succeeded",
    tests: { passed: 12, failed: 0, skipped: 1 },
    repository: "example/atlas",
    githubRunId: 47,
  },
  artifact: {
    ownerRead: true,
    checkedAt: NOW - 1000,
    sessionId: "session-synthetic-17",
    turnId: "turn-4",
    id: "artifact-synthetic-17",
    path: "reports/retry.md",
    revision: REVISION,
    digest: DIGEST,
    readbackDigest: DIGEST,
    scope: "team-alpha",
    accessible: true,
    expiresAt: NOW + 100_000,
  },
  approval: {
    ownerRead: true,
    sessionId: "session-synthetic-17",
    turnId: "turn-4",
    authority: "acpmux",
    state: "approved",
  },
  pullRequest: { ownerRead: true, repository: "example/atlas", number: 17, headCommit: COMMIT, state: "open" },
  risks: ["Network interruption retry awaits an exact-build runtime test"],
};
const cases: Record<Props["caseName"], ReturnBriefInput> = {
  complete: base,
  transcript: {
    ...base,
    run: undefined,
    artifact: undefined,
    approval: undefined,
    pullRequest: { ...base.pullRequest!, ownerRead: false },
    risks: [],
  },
  "wrong-team": { ...base, viewerScope: "team-beta", approval: { ...base.approval!, state: "pending" } },
  stale: {
    ...base,
    run: { ...base.run!, commit: REVISION },
    artifact: { ...base.artifact!, checkedAt: NOW - 90_000 },
    pullRequest: { ...base.pullRequest!, headCommit: REVISION },
  },
  unknown: {
    ...base,
    run: { ...base.run!, state: "outcome_unknown", tests: undefined },
    artifact: { ...base.artifact!, readbackDigest: undefined },
    approval: { ...base.approval!, state: "unknown" },
  },
};

function GalleryReturnBrief({ caseName }: Props) {
  const [action, setAction] = useState<string | undefined>();
  return (
    <div className="acpmux-shell" style={{ display: "flex", height: "100%", justifyContent: "flex-end" }}>
      <SessionInfoPanel width={342} placement="overlay" title="Return brief" onClose={() => setAction(undefined)}>
        <div className="acpmux-session-info__body">
          <p className="acpmux-return-brief__fixture">SYNTHETIC FIXTURE · owner responses simulated</p>
          <ReturnBrief
            input={cases[caseName]}
            onReviewChanges={() => setAction("Review diff requested · production host would open existing Changes")}
            onOpenArtifact={(id, revision) =>
              setAction("Open " + id + " @ " + revision.slice(0, 12) + " requested · production host must reauthorize")
            }
          />
          {action && <output className="acpmux-return-brief__fixture">{action}</output>}
        </div>
      </SessionInfoPanel>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.return-brief",
  title: "Return brief · owner proof",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 320, normal: 410 },
  covers: ["agent-session/acpmux/session-info/ReturnBrief.tsx"],
  load: async () => GalleryReturnBrief,
  variants: {
    "verified-reopen": {
      note: "Synthetic current owner readback: matching run/turn/revision, SHA-256 file bytes, approval and GitHub PR. Open affordances defer to host.",
      props: { caseName: "complete" },
    },
    "transcript-only": {
      note: "Agent text and edited paths alone: no passing test, persisted file, approved permission or GitHub PR proof.",
      props: { caseName: "transcript" },
    },
    "wrong-team": {
      note: "Same immutable artifact and pending permission, different current viewer account: refuse artifact Open.",
      props: { caseName: "wrong-team" },
    },
    "changed-head": {
      note: "Changed commit/PR head and stale artifact owner read: never reuse prior successful evidence.",
      props: { caseName: "stale" },
    },
    "outcome-unknown": {
      note: "Owner cannot confirm the original job, upload digest or permission outcome; preserve unknown states without replay.",
      props: { caseName: "unknown" },
    },
  },
});
