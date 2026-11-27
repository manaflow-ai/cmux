import { describe, expect, test } from "bun:test";
import { autocloudTuiVerdict } from "./cloud-journey";

describe("autocloudTuiVerdict", () => {
  const ready = "[cloud vm_1 · readiness 100 · live]\n";
  test("passes on readiness 100 and an agent line with the word", () => {
    expect(autocloudTuiVerdict(`${ready}> Reply with the single word pong.\npong\n`, "pong")).toBeNull();
  });
  test("the prompt line alone is no reply", () => {
    expect(autocloudTuiVerdict(`${ready}> Reply with the single word pong.\n  · Bash\n`, "pong")).toBe("no agent line says pong");
  });
  test("names readiness short of 100", () => {
    expect(autocloudTuiVerdict("[cloud vm_1 · readiness 80 · attaching]\nPong.\n", "pong")).toBe("readiness never reached 100");
  });
  test("the stub run takes any agent line", () => {
    expect(autocloudTuiVerdict(`${ready}> hi\nStub reply n1.\n`, null)).toBeNull();
    expect(autocloudTuiVerdict(`${ready}> hi\n`, null)).toBe("no agent line");
  });
});
