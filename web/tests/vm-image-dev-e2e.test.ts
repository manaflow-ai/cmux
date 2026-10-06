import { describe, expect, test } from "bun:test";
import { assertDevOrigin, readEnvFile } from "../scripts/cmux-vm-image/dev-e2e";

describe("dev end-to-end script guards", () => {
  test("refuses every origin except the development API", () => {
    expect(() => assertDevOrigin("https://cmux-api-development.debussy.workers.dev")).not.toThrow();
    for (const origin of ["https://cloud-api.cmux.dev", "https://cloud-api-staging.cmux.dev", "http://cmux-api-development.debussy.workers.dev", "https://evil.example"]) {
      expect(() => assertDevOrigin(origin)).toThrow(/development only/);
    }
  });
  test("reads KEY=value files without exposing other lines", () => {
    expect(readEnvFile('# c\nexport A="x y"\nB=z\nnot a line\n')).toEqual({ A: "x y", B: "z" });
  });
});
