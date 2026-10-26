// Austin, 2026-10-25: "while the screenshot is loading, i can also optimistically in the UI press
// backspace and it deletes it before the image loads... we shouldnt need to wait before the image
// is done loading before removing it". Backspace at the prompt's start takes back the last chip the
// strip shows: a loading (or failed) tile is drawn after the staged chips, so it goes first.
import { describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { backspacedChip, type PendingAttachment } from "../src/agent-session/acpmux/composer/attachmentIntake";

const key = { key: "Backspace", repeat: false, shiftKey: false, altKey: false, metaKey: false, ctrlKey: false };
const staged = (id: string) => ({ id, kind: "image", name: `${id}.png`, mimeType: "image/png" }) as ComposerAttachment;
const loading = (id: string): PendingAttachment => ({ id, name: `${id}.png`, image: true });

describe("Backspace at the prompt's start", () => {
  test("takes back a screenshot still loading, without waiting for it", () => {
    expect(backspacedChip(key, true, [], [loading("shot")])).toEqual({ pending: "shot" });
  });

  test("takes the loading tile before the staged chips it is drawn after", () => {
    expect(backspacedChip(key, true, [staged("a")], [loading("b"), loading("c")])).toEqual({ pending: "c" });
  });

  test("takes back a tile that failed to load", () => {
    expect(backspacedChip(key, true, [], [{ ...loading("bad"), failed: "The disk is full." }])).toEqual({
      pending: "bad",
    });
  });

  test("takes the last staged chip when nothing is loading", () => {
    expect(backspacedChip(key, true, [staged("a"), staged("b")], [])).toEqual({ staged: "b" });
  });

  test("leaves chips alone away from the start, on a held key, or with a modifier", () => {
    const chips = [loading("shot")];
    expect(backspacedChip(key, false, [], chips)).toBeUndefined();
    expect(backspacedChip({ ...key, repeat: true }, true, [], chips)).toBeUndefined();
    expect(backspacedChip({ ...key, altKey: true }, true, [], chips)).toBeUndefined();
    expect(backspacedChip({ ...key, key: "Delete" }, true, [], chips)).toBeUndefined();
    expect(backspacedChip(key, true, [], [])).toBeUndefined();
  });
});
