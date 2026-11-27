// l10n-allow-file: synthetic file names and host errors for a debug reader.
// `debug.agent_pane chat_state` reads the composer's attachment tiles, so a capture can tell a tile
// still uploading from one that failed and why (Leo, 2026-10-31: "idk what's going on with video
// attachments": a capture showed a tile spinning and could not say why).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { composerAttachmentsState } from "../src/agent-session/acpmux/composerAttachmentsState";

const page = (html: string) => new JSDOM(`<!doctype html><div class="acpmux-composer">${html}</div>`).window.document;

test("lists loading, uploading, failed and staged tiles in the strip and in the prompt", () => {
  const doc = page(`
    <div class="acpmux-attachment acpmux-attachment-image acpmux-attachment-pending" aria-busy="true" aria-label="a.mov"></div>
    <div class="acpmux-attachment acpmux-attachment-image acpmux-attachment-pending" aria-busy="true" aria-label="b.mov">
      <progress aria-label="b.mov" max="100" value="42"></progress>
    </div>
    <div class="acpmux-attachment acpmux-attachment-image acpmux-attachment-failed" aria-label="c.mov"
      title="The upload timed out: the app did not answer."><button class="acpmux-attachment-retry"></button></div>
    <div class="acpmux-attachment acpmux-attachment-image acpmux-attachment-video" title="d.mov"></div>
    <span class="acpmux-md-inline-chip" data-state="loading" aria-busy="true" aria-label="e.mov"></span>
    <span class="acpmux-md-inline-chip" data-state="ready" data-chip="strip">
      <div class="acpmux-attachment acpmux-attachment-file" title="g.zip"></div>
    </span>
    <span class="acpmux-md-inline-chip" data-state="failed" aria-label="f.mov" title="The app refused the agent connection."></span>
  `);
  expect(composerAttachmentsState(doc)).toEqual([
    { name: "a.mov", state: "loading" },
    { name: "b.mov", state: "loading", percent: 42 },
    { name: "c.mov", state: "failed", reason: "The upload timed out: the app did not answer.", retry: true },
    { name: "d.mov", state: "staged" },
    { name: "e.mov", state: "loading" },
    { name: "g.zip", state: "staged" },
    { name: "f.mov", state: "failed", reason: "The app refused the agent connection.", retry: false },
  ]);
});

test("an empty composer has no tiles", () => {
  expect(composerAttachmentsState(page(""))).toEqual([]);
});
