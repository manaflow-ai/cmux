// The gallery's controls live in the URL: a query reads the same in the web gallery and in the
// native one (schemas/gallery/env-vectors.json, which CmuxNextGalleryTests replays too).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { readEnv, type GalleryEnv } from "../src/gallery/env";

const vectors = JSON.parse(
  fs.readFileSync(path.join(import.meta.dir, "../../schemas/gallery/env-vectors.json"), "utf8"),
) as { vectors: { query: Record<string, string>; env: GalleryEnv }[] };

test("each shared vector's query reads as its value set", () => {
  expect(vectors.vectors.length).toBeGreaterThan(5);
  for (const vector of vectors.vectors) expect(readEnv(new URLSearchParams(vector.query))).toEqual(vector.env);
});
