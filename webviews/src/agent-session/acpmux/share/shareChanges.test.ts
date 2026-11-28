import { expect, test } from "bun:test";
import { onShareChanged, shareChanged } from "./shareChanges";

test("a change reaches only its own chat's listeners, until they stop", () => {
  const heard: string[] = [];
  const stopA = onShareChanged("acp_a", () => heard.push("a"));
  const stopB = onShareChanged("acp_b", () => heard.push("b"));
  shareChanged("acp_a");
  shareChanged("acp_c");
  shareChanged(42);
  shareChanged("");
  expect(heard).toEqual(["a"]);
  stopA();
  shareChanged("acp_a");
  shareChanged("acp_b");
  expect(heard).toEqual(["a", "b"]);
  stopB();
});
