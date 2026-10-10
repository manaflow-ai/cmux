// l10n-allow-file: gallery fixture labels and continuation text, not shipped UI.
//
// The review is the only point where a handoff's context, checkpoint and approved memory
// references become a prompt. Keep the gallery entry centered on that safety boundary: the
// target can edit a draft, but Start stays gated until a checkpoint is explicitly confirmed.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { HandoffReviewMessage } from "./ReviewMessage";
import { handoffStrings } from "./strings";
import type { Handoff } from "./protocol";
import type { HandoffClientState } from "./client";
import type { HandoffStrings } from "./strings";

type Props = Omit<ComponentProps<typeof HandoffReviewMessage>, "strings"> & { strings?: HandoffStrings };

const coverage: Handoff["source"]["coverage"] = [
  { item: "transcript", status: "included", detail: "Recent messages" },
  { item: "tool_output", status: "summarized", detail: "Large outputs summarized" },
  { item: "plan", status: "included", detail: null },
  { item: "files", status: "included", detail: "Checkpoint-backed files" },
  { item: "memory", status: "omitted", detail: "Only approved references are carried" },
  { item: "checkpoint", status: "included", detail: "User-attested repository state" },
  { item: "model", status: "included", detail: "Model and policy" },
];

const source: Handoff["source"] = {
  sessionId: "handoff-source-gallery",
  harness: "claude",
  cwd: "/Users/you/src/cmux",
  seq: 184,
  coverage,
  enforcement: {
    label: "native_policy",
    isolation: "unverified",
    policy: "approve-edits",
    detail: "Filesystem and network isolation have not been verified for this session.",
  },
};

const target: Handoff["target"] = {
  sessionId: "handoff-target-gallery",
  harness: "codex",
  cwd: source.cwd,
  coverage,
  enforcement: {
    label: "native_policy",
    isolation: "unverified",
    policy: "approve-edits",
    detail: "Filesystem and network isolation have not been verified for this session.",
  },
};

const baseCapsule: Handoff["capsule"] = {
  text: "Continue the UI parity pass from the source chat. Check the current gallery receipt before editing the composer and keep the interaction latency measurement intact.",
  maxBytes: 65_536,
  context: { fromSeq: 132, toSeq: 184, truncated: false, bytes: 2_104, totalBytes: 2_104 },
  checkpoint: {
    ref: "refs/cmux/handoff-gallery-2026-10-10",
    attestedBy: "user",
    attestedAt: "2026-10-10T18:00:00Z",
  },
  memoryRefs: ["MEMORY.md:120-128"],
};

function record(
  overrides: Partial<Pick<Handoff, "state" | "promptId" | "turnId">> & { capsule?: Handoff["capsule"] } = {},
): Handoff {
  return {
    handoffId: "0199-gallery-handoff-0000-000000000001",
    handoffKey: "gallery-handoff-review",
    state: "draft",
    revision: 3,
    source,
    target,
    capsule: baseCapsule,
    promptId: null,
    turnId: null,
    createdAt: "2026-10-10T17:55:00Z",
    updatedAt: "2026-10-10T18:00:00Z",
    ...overrides,
  };
}

const draft = record();
const noCheckpoint = record({
  capsule: { ...baseCapsule, checkpoint: null, memoryRefs: [] },
});
const memoryOverflow = record({
  capsule: {
    ...baseCapsule,
    memoryRefs: Array.from({ length: 33 }, (_, index) => `MEMORY.md:${index + 1}`),
  },
});
const starting = record({ state: "starting", promptId: "0199-gallery-prompt-0000-000000000001" });
const started = record({
  state: "started",
  promptId: "0199-gallery-prompt-0000-000000000001",
  turnId: "0199-gallery-turn-0000-000000000001",
});

const ready: HandoffClientState = { ready: true };
const startingState: HandoffClientState = { ready: true, busy: "starting" };
const startedState: HandoffClientState = {
  ready: true,
  receipt: {
    handoffId: started.handoffId,
    targetSessionId: target.sessionId,
    promptId: started.promptId!,
    turnId: started.turnId,
    outcome: "started",
  },
};
const errorState: HandoffClientState = { ready: true, error: "Couldn't save this review." };

function propsFor(reviewRecord: Handoff, state: HandoffClientState = ready): Props {
  return {
    record: reviewRecord,
    state,
    onSave: async () => reviewRecord,
    onStart: async () => undefined,
    onReturn: () => undefined,
    onDiscard: () => undefined,
    onReload: () => undefined,
  };
}

function GalleryReview(props: Props) {
  // Resolve after the gallery frame installs __cmuxPaneStrings. Resolving this at module load
  // time falls back to raw handoff keys in the static gallery bundle.
  const strings = handoffStrings();
  const [reviewRecord, setReviewRecord] = useState(props.record);
  const [action, setAction] = useState("");
  return (
    <div className="handoff-review-gallery" data-handoff-action={action}>
      <HandoffReviewMessage
        {...props}
        strings={strings}
        record={reviewRecord}
        onSave={async (review) => {
          const saved: Handoff = {
            ...reviewRecord,
            revision: reviewRecord.revision + 1,
            updatedAt: "2026-10-10T18:01:00Z",
            capsule: {
              ...reviewRecord.capsule,
              text: review.capsule,
              memoryRefs: review.approvedMemoryReferences,
              checkpoint: review.checkpoint.confirmed
                ? {
                    ref: review.checkpoint.reference,
                    attestedBy: "user",
                    attestedAt: "2026-10-10T18:01:00Z",
                  }
                : null,
            },
          };
          setReviewRecord(saved);
          setAction("saved");
          return saved;
        }}
        onStart={async () => {
          setAction("started");
          return {
            handoffId: reviewRecord.handoffId,
            targetSessionId: reviewRecord.target.sessionId,
            promptId: reviewRecord.promptId ?? reviewRecord.handoffId,
            turnId: null,
            outcome: "started" as const,
          };
        }}
        onReturn={() => setAction("returned")}
        onDiscard={() => setAction("discarded")}
        onReload={() => setAction("reloaded")}
      />
    </div>
  );
}

const edit: Play = async (ctx) => {
  await ctx.type("\nThe source's latest decision is preserved.", { selector: ".acpmux-handoff-review textarea" });
  await ctx.click({ selector: ".acpmux-handoff-review details:not(.acpmux-handoff-coverage) > summary" });
  await ctx.waitFor(
    () => ctx.document.querySelector(".acpmux-handoff-review details:not(.acpmux-handoff-coverage)[open]") !== null,
  );
  await ctx.type("MEMORY.md:200-204", {
    selector: ".acpmux-handoff-review details:not(.acpmux-handoff-coverage) textarea",
  });
  await ctx.waitFor(
    () =>
      ctx.document
        .querySelector<HTMLTextAreaElement>(".acpmux-handoff-review details:not(.acpmux-handoff-coverage) textarea")
        ?.value.includes("MEMORY.md:200-204") ?? false,
  );
};

const checkpointGating: Play = async (ctx) => {
  await ctx.type("refs/cmux/gallery-confirmed", { selector: '.acpmux-handoff-review input:not([type="checkbox"])' });
  await ctx.click({ selector: ".acpmux-handoff-confirm input[type=checkbox]" });
  await ctx.waitFor(() => {
    const button = ctx.document.querySelector<HTMLButtonElement>('button[type="submit"]');
    return button !== null && !button.disabled;
  });
  await ctx.focus({ selector: '.acpmux-handoff-review button[type="submit"]' });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[data-handoff-action="started"]') !== null);
};

const memoryDisclosure: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-handoff-review details:not(.acpmux-handoff-coverage) > summary" });
  await ctx.waitFor(
    () => ctx.document.querySelector(".acpmux-handoff-review details:not(.acpmux-handoff-coverage)[open]") !== null,
  );
};

const validation: Play = async (ctx) => {
  await ctx.focus({ selector: '.acpmux-handoff-review button[type="submit"]' });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[role="alert"]')?.textContent?.includes("at most 32") ?? false);
};

export default componentEntry<Props>({
  id: "agent-pane.handoff-review-message",
  title: "Handoff review message",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 440, normal: 680, wide: 820 },
  anchors: [{ selector: ".acpmux-handoff-provenance" }],
  covers: ["agent-session/acpmux/handoff/ReviewMessage.tsx#HandoffReviewMessage"],
  styles: () => Promise.all([import("../styles.css"), import("./styles.css")]),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Editing or opening a disclosure must leave the handoff provenance anchored at the top of the review.",
    },
    layoutShiftMax: {
      value: 0.05,
      reason:
        "The memory disclosure is an intentional in-flow expansion; unrelated review controls must remain stable.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Draft edits and checkpoint confirmation are local controls and should stay responsive.",
    },
    settleMaxMs: {
      value: 500,
      reason: "Review field edits and disclosure state should settle within half a second on the gallery host.",
    },
  },
  load: async () => GalleryReview,
  variants: {
    draft: {
      note: "A saved draft shows the source/target provenance, editable context, an attested checkpoint and approved memory references.",
      props: propsFor(draft),
    },
    edit: {
      note: "Context and approved memory references remain editable, with the real blur-save path receiving the changed draft.",
      props: propsFor(draft),
      play: edit,
    },
    "checkpoint-gating": {
      note: "Start stays disabled until a repository checkpoint is entered and the user confirms its saved working changes; Enter then starts the review.",
      props: propsFor(noCheckpoint),
      play: checkpointGating,
    },
    "memory-disclosure": {
      note: "Approved memory references stay behind a disclosure, with the explicit one-reference-per-line consent copy visible when opened.",
      props: propsFor(draft),
      play: memoryDisclosure,
    },
    "validation-error": {
      note: "The real review validator rejects an overlong approved-memory list before the start callback is reached.",
      props: propsFor(memoryOverflow),
      play: validation,
    },
    error: {
      note: "A host save error remains visible as an alert while the draft controls stay available for recovery.",
      props: propsFor(draft, errorState),
    },
    starting: {
      note: "While the target is starting, every review field is disabled and the primary action reports Starting.",
      props: propsFor(starting, startingState),
    },
    started: {
      note: "After the receipt arrives, the started handoff keeps its review read-only and exposes the saved target state.",
      props: propsFor(started, startedState),
    },
  },
});
