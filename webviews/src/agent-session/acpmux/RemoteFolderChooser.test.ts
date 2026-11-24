import { expect, test } from "bun:test";
import { chooseRemoteFolder } from "./RemoteFolderChooser";

test("a second ask settles the first with no pick", async () => {
  const first = chooseRemoteFolder("lab-box");
  void chooseRemoteFolder("lab-box");
  expect(await first).toBeUndefined();
});
