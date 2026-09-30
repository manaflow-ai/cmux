import { expect, test } from "vite-plus/test";
import { runTurn, type Model, type ModelRequest } from "../src/index.ts";

test("tool calls run and feed back until the model answers", async () => {
  const requests: ModelRequest[] = [];
  const model: Model = async (request) => {
    requests.push(request);
    if (requests.length === 1) {
      return {
        output: [
          { type: "function_call", call_id: "c1", name: "run", arguments: '{"code":"1+1"}' },
        ],
      };
    }
    return { output: [{ type: "message", content: [{ type: "output_text", text: "It is 2." }] }] };
  };
  const result = await runTurn({
    model,
    instructions: "i",
    input: [{ role: "user", content: "1+1?" }],
    runTool: async (call) => (call.name === "run" ? "2" : "?"),
  });
  expect(result.text).toBe("It is 2.");
  expect(result.steps).toBe(2);
  expect(requests[1].input.slice(1)).toEqual([
    { type: "function_call", call_id: "c1", name: "run", arguments: '{"code":"1+1"}' },
    { type: "function_call_output", call_id: "c1", output: "2" },
  ]);
});

test("a throwing tool reports the error to the model instead of ending the turn", async () => {
  let calls = 0;
  const model: Model = async (request) => {
    calls++;
    const last = request.input.at(-1);
    if (calls === 1)
      return { output: [{ type: "function_call", call_id: "c1", name: "run", arguments: "{}" }] };
    return {
      output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(last) }] }],
    };
  };
  const result = await runTurn({
    model,
    instructions: "i",
    input: [],
    runTool: async () => {
      throw new Error("sandbox down");
    },
  });
  expect(result.text).toContain("error: sandbox down");
});

test("endless tool loops stop at maxSteps", async () => {
  const model: Model = async () => ({
    output: [{ type: "function_call", call_id: "c", name: "run", arguments: "{}" }],
  });
  await expect(
    runTurn({ model, instructions: "i", input: [], runTool: async () => "", maxSteps: 3 }),
  ).rejects.toThrow("within 3");
});
