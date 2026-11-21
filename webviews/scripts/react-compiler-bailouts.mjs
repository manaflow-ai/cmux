// Which components and hooks in the given files the React Compiler (babel-plugin-react-compiler, the pass every
// webviews build runs, reactCompiler.mjs) compiles, and which it leaves as written, with the reason. A component it
// leaves is not memoized at all: every render of it makes every element and callback again, so each child without
// its own React.memo renders too.
//
//   bun scripts/react-compiler-bailouts.mjs FILE...
import { transformAsync } from "@babel/core";
import { readFileSync } from "node:fs";
import path from "node:path";
import { REACT_COMPILER_TARGET } from "../reactCompiler.mjs";

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("usage: bun scripts/react-compiler-bailouts.mjs FILE...");
  process.exit(2);
}
let left = 0;
for (const file of files) {
  const events = [];
  await transformAsync(readFileSync(file, "utf8"), {
    filename: path.resolve(file),
    babelrc: false,
    configFile: false,
    parserOpts: { plugins: ["typescript", "jsx"] },
    plugins: [
      [
        "babel-plugin-react-compiler",
        {
          target: REACT_COMPILER_TARGET,
          logger: { logEvent: (_filename, event) => events.push(event) },
        },
      ],
    ],
  });
  for (const event of events) {
    const line = event.fnLoc?.start?.line ?? event.detail?.loc?.start?.line ?? "?";
    if (event.kind === "CompileSuccess") {
      console.log(`compiled  ${file}:${line} ${event.fnName ?? "(anonymous)"} memo slots ${event.memoSlots}`);
    } else if (event.kind === "CompileError" || event.kind === "CompileSkip" || event.kind === "PipelineError") {
      left += 1;
      const detail = event.detail?.options ?? event.detail ?? {};
      const reason = detail.reason ?? event.reason ?? event.kind;
      const at = detail.loc?.start?.line ?? detail.details?.[0]?.loc?.start?.line;
      console.log(
        `LEFT      ${file}:${line} ${event.fnName ?? ""} ${event.kind}: ${String(reason).slice(0, 300)}${at ? ` (line ${at})` : ""}`,
      );
      if (process.env.BAILOUT_RAW) console.log(`  raw ${JSON.stringify(event).slice(0, 800)}`);
    }
  }
}
console.log(`REACT-COMPILER-BAILOUTS left ${left}`);
