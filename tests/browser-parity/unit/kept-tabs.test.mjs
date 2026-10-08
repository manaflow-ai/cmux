// Each parity scenario on a host backend closes the tabs it leaves open
// (kept tabs), so a host reused across scenarios does not pile them up
// (chief, 2026-10-06). The runner lists the tab ids before the first cell
// and closes every other tab after the last, also when a cell fails.
//
//   node --test tests/browser-parity/unit/kept-tabs.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { runCliCells } from "../run.mjs";

function fakeCli(failCell = false) {
  const inputs = [];
  const exec = async (argv, { input } = {}) => {
    inputs.push(input ?? "");
    if ((input ?? "").includes("__PARITY_TABS__")) return { code: 0, out: '__PARITY_TABS__["before"]\n', err: "" };
    if (failCell && input === "cell") throw new Error("cell crashed");
    return { code: 0, out: "", err: "" };
  };
  return { inputs, exec };
}

const spec = (exec) => ({
  evalArgv: (session) => ["eval", ...(session ? ["--session", session] : [])],
  resetArgv: (session) => ["close", "--session", session],
  exec,
  closeKeptTabs: true,
});

test("tabs a scenario leaves open are closed after it", async () => {
  const cli = fakeCli();
  await runCliCells([{ code: "cell", session: null }], "s", spec(cli.exec));
  assert.match(cli.inputs[0], /__PARITY_TABS__/);
  const last = cli.inputs.at(-1);
  assert.match(last, /"before"/);
  assert.match(last, /\.close\(\)/);
});

test("they are closed also when a cell fails", async () => {
  const cli = fakeCli(true);
  await assert.rejects(runCliCells([{ code: "cell", session: null }], "s", spec(cli.exec)), /cell crashed/);
  assert.match(cli.inputs.at(-1), /\.close\(\)/);
});
