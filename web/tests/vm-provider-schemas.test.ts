import { describe, expect, test } from "bun:test";
import { parseFreestyleExecResponse } from "../services/vms/drivers/schemas";
import { ProviderError } from "../services/vms/drivers/types";

describe("parseFreestyleExecResponse", () => {
  test("maps statusCode to exitCode and normalizes null streams", () => {
    expect(parseFreestyleExecResponse("exec", { statusCode: 2, stdout: null, stderr: "boom" })).toEqual({
      exitCode: 2,
      stdout: "",
      stderr: "boom",
    });
  });

  test("a missing statusCode is a ProviderError, never exit-0 success", () => {
    expect(() => parseFreestyleExecResponse("exec(vm-1)", { stdout: "looks fine" })).toThrow(
      ProviderError,
    );
    expect(() => parseFreestyleExecResponse("exec(vm-1)", { stdout: "looks fine" })).toThrow(
      /exec\(vm-1\) returned an unexpected response shape/,
    );
  });

  test("an explicit null statusCode means the command timed out", () => {
    expect(parseFreestyleExecResponse("exec", { statusCode: null })).toEqual({
      exitCode: 124, stdout: "", stderr: "",
    });
  });

  test("a non-numeric statusCode is rejected", () => {
    expect(() => parseFreestyleExecResponse("exec", { statusCode: "0" })).toThrow(ProviderError);
  });
});
