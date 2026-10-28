// A Chief's picture (backgrounds plan phase 4): a still is placed in the circle (drag, zoom) and
// drawn at 512 px so a photo of any size fits the daemon's 1 MB; a GIF goes as it is; Use Default
// Picture clears it on the daemon (`clear: true`).
import { expect, test } from "bun:test";
import { DaemonPeople } from "../src/pages/home-channels/daemonPeople";
import {
  CENTERED,
  cropSquare,
  dragCrop,
  preparePicture,
  PICTURE_SIDE,
  withinPixels,
} from "../src/pages/home-channels/picture";

test("the crop square stays inside the image at every zoom and drag", () => {
  // A landscape photo: centered, the square is its full height in the middle.
  expect(cropSquare(4000, 3000, CENTERED)).toEqual({ x: 500, y: 0, side: 3000 });
  // Zoomed 2x and pushed to the right edge.
  expect(cropSquare(4000, 3000, { zoom: 2, x: 1, y: 0 })).toEqual({ x: 2500, y: 750, side: 1500 });
  // Out-of-range values are clamped, never past the edges.
  const wild = cropSquare(4000, 3000, { zoom: 99, x: -5, y: Number.NaN });
  expect(wild.x).toBe(0);
  expect(wild.side).toBe(750);
  expect(wild.y + wild.side).toBeLessThanOrEqual(3000);
});

test("dragging the picture right shows more of its left", () => {
  const moved = dragCrop(CENTERED, 4000, 3000, 160, 40, 0);
  expect(moved.x).toBeLessThan(0);
  expect(moved.y).toBe(0);
  // A square image has no room to move at zoom 1.
  expect(dragCrop(CENTERED, 1000, 1000, 160, 40, 40)).toEqual(CENTERED);
  // A drag far past the edge stops at it.
  expect(dragCrop(CENTERED, 4000, 3000, 160, 100_000, 0).x).toBe(-1);
});

test("a still is drawn at its crop, a GIF goes as it is, and sizes are refused with the right reason", async () => {
  const drawn: Array<{ rect: { x: number; y: number; side: number }; side: number }> = [];
  const render = async (_file: Blob, rect: { x: number; y: number; side: number }, side: number) => {
    drawn.push({ rect, side });
    return { mediaType: "image/png", data: "cG5n" };
  };
  const photo = new File([new Uint8Array(5 * 1024 * 1024)], "big.jpg", { type: "image/jpeg" });
  // 5 MB is past the daemon's 1 MB, but a still is drawn down, not refused.
  expect(await preparePicture(photo, { zoom: 2, x: 0, y: 0 }, { width: 4000, height: 3000 }, render)).toEqual({
    mediaType: "image/png",
    data: "cG5n",
  });
  expect(drawn[0]).toEqual({ rect: { x: 1250, y: 750, side: 1500 }, side: PICTURE_SIDE });
  const huge = new File([new Uint8Array(21 * 1024 * 1024)], "huge.png", { type: "image/png" });
  expect(await preparePicture(huge, CENTERED, { width: 10, height: 10 }, render)).toEqual({ error: "tooBig" });
  const gif = new File([new Uint8Array([71, 73, 70])], "cat.gif", { type: "image/gif" });
  expect(await preparePicture(gif, CENTERED, { width: 1, height: 1 }, render)).toEqual({
    mediaType: "image/gif",
    data: "R0lG",
  });
  expect(drawn.length).toBe(1);
  const bigGif = new File([new Uint8Array(2 * 1024 * 1024)], "big.gif", { type: "image/gif" });
  expect(await preparePicture(bigGif, CENTERED, { width: 1, height: 1 }, render)).toEqual({ error: "size" });
  const svg = new File(["<svg/>"], "a.svg", { type: "image/svg+xml" });
  expect(await preparePicture(svg, CENTERED, { width: 1, height: 1 }, render)).toEqual({ error: "type" });
  // A small file that decodes to too many pixels is refused before anything decodes it.
  const bomb = new File([new Uint8Array(1000)], "bomb.png", { type: "image/png" });
  const before = drawn.length;
  expect(await preparePicture(bomb, CENTERED, { width: 30_000, height: 30_000 }, render)).toEqual({ error: "pixels" });
  expect(drawn.length).toBe(before);
  expect(withinPixels({ width: 8000, height: 6000 })).toBe(true);
  expect(withinPixels({ width: 10_000, height: 6000 })).toBe(false);
  // A still small enough is drawn at its own size, never scaled up.
  await preparePicture(
    new File([new Uint8Array(10)], "s.png", { type: "image/png" }),
    CENTERED,
    { width: 200, height: 300 },
    render,
  );
  expect(drawn.at(-1)!.side).toBe(200);
});

test("Use Default Picture clears the Chief's picture on the daemon", async () => {
  const sent: Array<{ op: string; params: Record<string, unknown> }> = [];
  const socket = {
    operation: async (op: string, params: Record<string, unknown>) => {
      sent.push({ op, params });
      return { value: { id: "agent_1", display_name: "Ada", role: "", rev: 2 } };
    },
  };
  const people = new DaemonPeople(
    socket as never,
    () => "user_local",
    async () => true,
  );
  await people.setChiefAvatar("agent_1", null, "k1");
  expect(sent[0].op).toBe("chief.profile.avatar.set");
  expect(sent[0].params).toMatchObject({ chief: "agent_1", clear: true });
  expect("data" in sent[0].params).toBe(false);
  await people.setChiefAvatar("agent_1", { mediaType: "image/png", data: "cG5n" }, "k2");
  expect(sent[1].params).toMatchObject({ chief: "agent_1", media_type: "image/png", data: "cG5n" });
  expect("clear" in sent[1].params).toBe(false);
});
