import { expect, test } from "bun:test";
import { readCuaProof } from "../scripts/devbox-cua-smoke";

test.each(["ECONNRESET", "EPIPE", "ETIMEDOUT"])("evidence survives an interrupted download (%s)", async (code) => {
  const screenshot = new Uint8Array([137, 80, 78, 71]);
  let attempts = 0;
  const result = await readCuaProof(async () => {
    if (++attempts === 1) throw Object.assign(new Error("interrupted response body"), { code });
    return screenshot;
  });
  expect(result).toEqual(screenshot);
  expect(attempts).toBe(2);
});

test("persistent connection failures fail evidence collection after three attempts", async () => {
  const failure = Object.assign(new Error("connection reset"), { code: "ECONNRESET" });
  let attempts = 0;
  await expect(readCuaProof(async () => { attempts++; throw failure; })).rejects.toBe(failure);
  expect(attempts).toBe(3);
});

test.each(["ENOENT", "EACCES", "NOT_FOUND"])("permanent evidence errors fail immediately (%s)", async (code) => {
  const failure = Object.assign(new Error("evidence unavailable"), { code });
  let attempts = 0;
  await expect(readCuaProof(async () => { attempts++; throw failure; })).rejects.toBe(failure);
  expect(attempts).toBe(1);
});
