// A chat's unsent composer images are kept in acpmux too, so they move with the chat (RFD 0138,
// "Attachments pending in the composer"): composer/carriedDraftImages.ts.
import { beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import {
  carriedChips,
  forgetHeld,
  MAX_CARRIED_IMAGES,
  noteBytes,
  readCarriedImages,
  writeCarriedImages,
} from "../src/agent-session/acpmux/composer/carriedDraftImages";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";

const surface = { id: "page-1", name: "Mac", kind: "app" as const };

const image = (id: string, data?: string): ComposerAttachment =>
  ({
    id,
    kind: "image",
    name: `${id}.png`,
    mimeType: "image/png",
    size: 3,
    ...(data ? { data } : {}),
  }) as ComposerAttachment;
const file = (id: string): ComposerAttachment => ({
  id,
  kind: "document",
  name: `${id}.pdf`,
  mimeType: "application/pdf",
  size: 3,
  data: "eA==",
});

type Call = { method: string; params: Record<string, unknown> };

function daemon(answer: (call: Call) => unknown) {
  const calls: Call[] = [];
  const request = async (method: string, params: Record<string, unknown>) => {
    const call = { method, params };
    calls.push(call);
    return answer(call);
  };
  return { calls, request };
}

/// composer_set's answer: an id per image, in order.
const setAnswer = (call: Call) => ({
  images: (call.params.images as Record<string, unknown>[]).map((img, n) => ({
    id: typeof img.id === "string" ? img.id : `sha-${n}-${String(img.data)}`,
    mimeType: "image/png",
  })),
});

beforeEach(() => forgetHeld());

describe("writing a draft's images", () => {
  test("only image chips go, with empty text under the page's surface", async () => {
    const { calls, request } = daemon(setAnswer);
    await writeCarriedImages(request, "s1", surface, [image("a", "QQ=="), file("f"), image("b", "Qg==")]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.method).toBe("_acpmux/composer_set");
    expect(calls[0]!.params).toMatchObject({ sessionId: "s1", surface, text: "" });
    expect(calls[0]!.params.images).toEqual([
      { type: "image", mimeType: "image/png", data: "QQ==", name: "a.png" },
      { type: "image", mimeType: "image/png", data: "Qg==", name: "b.png" },
    ]);
  });

  test("an image acpmux holds goes by id the next time, even once the host strips its bytes", async () => {
    const { calls, request } = daemon(setAnswer);
    await writeCarriedImages(request, "s1", surface, [image("a", "QQ==")]);
    await writeCarriedImages(request, "s1", surface, [image("a"), image("b", "Qg==")]);
    expect(calls[1]!.params.images).toEqual([
      { id: "sha-0-QQ==" },
      { type: "image", mimeType: "image/png", data: "Qg==", name: "b.png" },
    ]);
  });

  test("acpmux losing a held image sends the bytes again once", async () => {
    let refused = false;
    const { calls, request } = daemon((call) => {
      const images = call.params.images as Record<string, unknown>[];
      if (!refused && images.some((img) => typeof img.id === "string")) {
        refused = true;
        throw new AcpmuxRpcError({ message: "unknown", data: { reason: "composer.image.unknown" } });
      }
      return setAnswer(call);
    });
    await writeCarriedImages(request, "s1", surface, [image("a", "QQ==")]);
    await writeCarriedImages(request, "s1", surface, [image("a")]);
    expect(calls).toHaveLength(3);
    expect(calls[2]!.params.images).toEqual([{ type: "image", mimeType: "image/png", data: "QQ==", name: "a.png" }]);
  });

  test("an older write retry finishes before a newer removal", async () => {
    let rejectId!: (reason: Error) => void;
    const { calls, request } = daemon((call) => {
      const images = call.params.images as Record<string, unknown>[];
      if (images[0]?.id) return new Promise((_, reject) => { rejectId = reject; });
      return setAnswer(call);
    });
    await writeCarriedImages(request, "s1", surface, [image("a", "QQ==")]);
    const update = writeCarriedImages(request, "s1", surface, [image("a")]);
    const clear = writeCarriedImages(request, "s1", surface, []);
    rejectId(new AcpmuxRpcError({ message: "unknown", data: { reason: "composer.image.unknown" } }));
    await Promise.all([update, clear]);
    expect(calls.map(({ params }) => params.images)).toEqual([
      [{ type: "image", mimeType: "image/png", data: "QQ==", name: "a.png" }],
      [{ id: "sha-0-QQ==" }],
      [{ type: "image", mimeType: "image/png", data: "QQ==", name: "a.png" }],
      [],
    ]);
  });

  test("a removal writes no images, which clears the surface's draft", async () => {
    const { calls, request } = daemon(setAnswer);
    await writeCarriedImages(request, "s1", surface, [image("a", "QQ==")]);
    await writeCarriedImages(request, "s1", surface, []);
    expect(calls[1]!.params).toMatchObject({ text: "", images: [] });
  });

  test("other refusals reach the caller", async () => {
    const { request } = daemon(() => {
      throw new AcpmuxRpcError({ message: "moving", data: { reason: "transfer.moving" } });
    });
    await expect(writeCarriedImages(request, "s1", surface, [image("a", "QQ==")])).rejects.toBeInstanceOf(
      AcpmuxRpcError,
    );
  });

  test("at most 32 images go", () => {
    const many = Array.from({ length: 40 }, (_, n) => image(`i${n}`, "QQ=="));
    expect(carriedChips("s1", many)).toHaveLength(MAX_CARRIED_IMAGES);
  });

  test("bytes the host read are used for a chip a later write sends without them", () => {
    noteBytes("s1", [image("a", "QQ==")]);
    expect(carriedChips("s1", [image("a")])[0]!.data).toBe("QQ==");
    // Another chat's bytes are not this one's.
    expect(carriedChips("s2", [image("a")])).toEqual([]);
  });
});

describe("reading a moved chat's images", () => {
  test("resumes the page's draft and reads its available bytes in order", async () => {
    const { calls, request } = daemon(({ method, params }) => {
      if (method === "_acpmux/composer_set") {
        return { images: [{ id: "h1", name: "a.png" }, { id: "h2" }] };
      }
      return params.id === "h2" ? {} : { mimeType: "image/png", data: "QQ==" };
    });
    const chips = await readCarriedImages(request, "s1", surface);
    expect(calls[0]).toEqual({ method: "_acpmux/composer_set", params: { sessionId: "s1", surface, resume: true } });
    expect(chips.map((chip) => [chip.id, chip.name, chip.data])).toEqual([["carried-h1", "a.png", "QQ=="]]);
  });

  test("a populated native store resumes without redownloading the images", async () => {
    const { calls, request } = daemon(() => ({ images: [{ id: "h1" }] }));
    expect(await readCarriedImages(request, "s1", surface, true)).toEqual([]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.params.resume).toBe(true);
  });

  test("an older daemon refusing a resume leaves the draft alone", async () => {
    const { calls, request } = daemon(() => { throw new Error("text is required"); });
    expect(await readCarriedImages(request, "s1", surface)).toEqual([]);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.params).not.toHaveProperty("text");
  });
});
