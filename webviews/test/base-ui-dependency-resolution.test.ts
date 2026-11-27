// test/preload.ts loads @base-ui/utils and @floating-ui/react-dom, which are dependencies of
// @base-ui/react and not of this package. An install that leaves them nested under
// node_modules/@base-ui/react/node_modules (as one CI shard's did) made the preload's bare import
// fail, and with it every file in that shard. This builds that nested layout and checks the
// preload's resolver still finds the copy Base UI loads.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { resolveBaseUiDependency } from "./support/baseUiDependency";

const root = realpathSync(mkdtempSync(join(tmpdir(), "base-ui-nested-")));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function write(path: string, text: string) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), text);
}

write("package.json", JSON.stringify({ name: "webviews-fixture", dependencies: { "@base-ui/react": "*" } }));
write("test/preload.ts", "");
const react = "node_modules/@base-ui/react";
write(
  `${react}/package.json`,
  JSON.stringify({ name: "@base-ui/react", exports: { "./tooltip": "./tooltip/index.js" } }),
);
write(`${react}/tooltip/index.js`, "");
const utils = `${react}/node_modules/@base-ui/utils`;
write(
  `${utils}/package.json`,
  JSON.stringify({ name: "@base-ui/utils", exports: { "./useIsoLayoutEffect": "./useIsoLayoutEffect.js" } }),
);
write(`${utils}/useIsoLayoutEffect.js`, "");
write(
  `${react}/node_modules/@floating-ui/react-dom/package.json`,
  JSON.stringify({ name: "@floating-ui/react-dom", main: "index.js" }),
);
write(`${react}/node_modules/@floating-ui/react-dom/index.js`, "");
const preload = join(root, "test/preload.ts");

test("the fixture is the layout that broke the shard: a bare import from the preload fails", () => {
  expect(() => Bun.resolveSync("@base-ui/utils/useIsoLayoutEffect", preload)).toThrow();
});

test("the preload resolves Base UI's nested @base-ui/utils", () => {
  expect(resolveBaseUiDependency("@base-ui/utils/useIsoLayoutEffect", preload)).toBe(
    join(root, utils, "useIsoLayoutEffect.js"),
  );
});

test("the preload resolves Base UI's nested @floating-ui/react-dom", () => {
  expect(resolveBaseUiDependency("@floating-ui/react-dom", preload)).toBe(
    join(root, react, "node_modules/@floating-ui/react-dom/index.js"),
  );
});
