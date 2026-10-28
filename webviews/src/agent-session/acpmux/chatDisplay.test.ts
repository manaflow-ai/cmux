import { expect, test } from "bun:test";
import { chatDisplayVariables, resolveChatDisplay } from "./chatDisplay";

test("the chat font setting scales the composer content tokens", () => {
  const display = resolveChatDisplay({ "agentPane.display.font.size": 20 });
  const variables = chatDisplayVariables(display);

  expect(variables["--cv-font-size"]).toBe("20px");
  expect(variables["--cv-content-scale"]).toBe("1.43");
  expect(variables["--cv-line-height"]).toBe("32.5px");
  expect(variables["--cv-code-size"]).toBe("18.57px");
  expect(variables["--cv-codeblock-size"]).toBe("17.14px");
  expect(variables["--cv-codeblock-line-height"]).toBe("28.57px");
});

test("resetting the chat font removes the override used by Cmd +/-", () => {
  const display = resolveChatDisplay({ "agentPane.display.font.size": 20 });
  const reset = chatDisplayVariables(resolveChatDisplay({}));

  expect(chatDisplayVariables(display)["--cv-font-size"]).toBe("20px");
  expect(reset["--cv-font-size"]).toBeNull();
  expect(reset["--cv-content-scale"]).toBeNull();
  expect(reset["--cv-line-height"]).toBeNull();
  expect(reset["--cv-code-size"]).toBeNull();
  expect(reset["--cv-codeblock-size"]).toBeNull();
  expect(reset["--cv-codeblock-line-height"]).toBeNull();
});
