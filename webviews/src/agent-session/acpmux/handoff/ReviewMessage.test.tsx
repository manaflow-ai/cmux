import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import { HandoffReviewMessage } from "./ReviewMessage";
import type { Handoff } from "./protocol";
import { handoffStrings } from "./strings";

const session = {
  sessionId: "source",
  harness: "codex",
  cwd: "/project",
  coverage: [],
  enforcement: { label: "native_policy", isolation: "unverified", policy: "default", detail: null },
} as const;

function render() {
  const record: Handoff = {
    handoffId: "review",
    handoffKey: "review",
    state: "draft",
    revision: 1,
    source: { ...session, coverage: [], seq: 1 },
    target: { ...session, coverage: [], sessionId: "target", harness: "claude" },
    capsule: {
      text: "Continue the source conversation.",
      maxBytes: 65536,
      context: { fromSeq: 0, toSeq: 1, truncated: false, bytes: 33, totalBytes: 33 },
      checkpoint: null,
      memoryRefs: [],
    },
    promptId: null,
    turnId: null,
    createdAt: "2026-11-02T00:00:00Z",
    updatedAt: "2026-11-02T00:00:00Z",
  };
  return new JSDOM(
    renderToStaticMarkup(
      <HandoffReviewMessage
        record={record}
        state={{ ready: true }}
        strings={handoffStrings()}
        onSave={async () => record}
        onStart={async () => undefined}
        onReturn={() => undefined}
        onDiscard={() => undefined}
        onReload={() => undefined}
      />,
    ),
  );
}

test("Continue can identify missing checkpoint and confirmation instead of silently disabling", () => {
  const dom = render();
  try {
    const form = dom.window.document.querySelector("form")!;
    const button = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
    const checkpoint = form.querySelector<HTMLInputElement>('input:not([type="checkbox"])')!;
    const confirmation = form.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
    const context = form.querySelector("textarea")!;
    expect(button.disabled).toBe(false);
    expect(form.checkValidity()).toBe(false);
    expect(checkpoint.validity.valueMissing).toBe(true);
    checkpoint.value = "refs/heads/saved-work";
    expect(form.checkValidity()).toBe(false);
    expect(confirmation.validity.valueMissing).toBe(true);
    confirmation.checked = true;
    expect(form.checkValidity()).toBe(true);
    context.value = "";
    expect(context.validity.valueMissing).toBe(true);
    expect(form.checkValidity()).toBe(false);
  } finally {
    dom.window.close();
  }
});
