import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import YAML from "yaml";
import { Parser, Lexer, Evaluator, data } from "@actions/expressions";

const root = new URL("../../../", import.meta.url).pathname;
const workflow = YAML.parse(fs.readFileSync(path.join(root, ".github/workflows/ci.yml"), "utf8"));

function context(value) {
  if (typeof value === "string") return new data.StringData(value);
  return new data.Dictionary(...Object.entries(value).map(([key, v]) => ({ key, value: context(v) })));
}
function evaluate(expression, values) {
  // GitHub accepts either bare or fully wrapped step conditions.
  expression = expression.trim().replace(/^\$\{\{([\s\S]*?)\}\}$/, "$1").trim();
  const ast = new Parser(new Lexer(expression).lex().tokens, Object.keys(values), []).parse();
  return new Evaluator(ast, context(values)).evaluate().coerceString();
}
function render(expression, values) {
  return expression.replace(/\$\{\{([\s\S]*?)\}\}/g, (_, code) => evaluate(code, values));
}

const scenarios = ["true", "false", ""].flatMap((layerHit) =>
  [true, false].map((enabled) => ({ layerHit, enabled })));
for (const jobName of ["app-host-unit-tests", "tests-build-and-lag"]) {
  for (const { layerHit, enabled } of scenarios) {
    test(`${jobName}: layers=${layerHit || "absent"}, R2=${enabled ? "enabled" : "disabled"}`, (t) => {
      const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-artifact-workflow-"));
      t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
      const bin = path.join(temporary, "bin");
      fs.mkdirSync(bin);
      const stub = `#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys, zipfile
from io import BytesIO
work = pathlib.Path(os.environ["RUNNER_TEMP"])
archive = BytesIO()
with zipfile.ZipFile(archive, "w") as z:
    item = zipfile.ZipInfo("app-host-products.aar", date_time=(2026, 1, 1, 0, 0, 0))
    z.writestr(item, b"opaque product and producer log")
blob = archive.getvalue()
if pathlib.Path(sys.argv[0]).name == "gh":
    assert sys.argv[1:] == ["api", "repos/manaflow-ai/cmux/actions/artifacts/123"]
    assert os.environ["GH_TOKEN"] == "read-only-job-token"
    (work / "metadata-called").touch()
    print(json.dumps({"id":123,"expired":False,"digest":"sha256:"+hashlib.sha256(blob).hexdigest(),"size_in_bytes":len(blob),"workflow_run":{"id":456}}))
else:
    assert sys.argv[-1] == "https://broker.example/v1/manaflow-ai/cmux/artifacts/123/"+hashlib.sha256(blob).hexdigest()+".zip"
    pathlib.Path(sys.argv[sys.argv.index("--output")+1]).write_bytes(blob)
`;
      for (const command of ["gh", "curl"]) fs.writeFileSync(path.join(bin, command), stub, { mode: 0o755 });
      const job = workflow.jobs[jobName];
      const restore = job.steps.find((step) => step.id === "r2-products");
      const fallback = job.steps.find((step) => step.name === "Download compiled app-host test product");
      const values = {
        github: { token: "read-only-job-token" },
        vars: { CI_ARTIFACT_R2_URL: enabled ? "https://broker.example" : "" },
        needs: { "macos-compile-admission": { outputs: { artifact_id: "123" } } },
        steps: {
          "restore-layers": { outputs: { hit: layerHit } },
          "r2-products": { outputs: { hit: "" } },
        },
      };
      const output = path.join(temporary, "output");
      const tryR2 = evaluate(restore.if, values) === "true";
      assert.equal(tryR2, layerHit !== "true");
      if (tryR2) execFileSync("bash", ["-e", "-c", restore.run], { cwd: root, env: {
        ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: temporary,
        GITHUB_OUTPUT: output, GITHUB_RUN_ID: "456", GITHUB_REPOSITORY: "manaflow-ai/cmux",
        ...Object.fromEntries(Object.entries(restore.env).map(([key, value]) => [key, render(value, values)])),
      } });
      const hit = tryR2
        ? Object.fromEntries(fs.readFileSync(output, "utf8").trim().split("\n").map((line) => line.split("="))).hit
        : "";
      values.steps["r2-products"].outputs.hit = hit;
      const download = evaluate(fallback.if, values) === "true";
      assert.equal(download, layerHit !== "true" && !enabled);
      // All routes still enter the same inner integrity/provenance restore;
      // only a verified layer assembly can select its alternate unpack path.
      const inner = job.steps.find((step) => step.name === "Restore compiled app-host test product");
      assert.equal(inner.if, undefined);
      assert.equal(inner.run, "scripts/ci/restore-app-host-test-product.sh");
      assert.equal(render(inner.env.CMUX_LAYER_RESTORED, values), layerHit);
      const wrapped = jobName === "app-host-unit-tests";
      assert.equal(fallback.uses, wrapped
        ? "./.github/actions/download-test-product"
        : "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131");
      assert.equal(render(fallback.with[wrapped ? "artifact-id" : "artifact-ids"], values), "123");
      assert.equal(fs.existsSync(path.join(temporary, "metadata-called")), tryR2 && enabled);
      assert.equal(fs.existsSync(path.join(temporary, "app-host-products")), tryR2 && enabled);
      if (tryR2 && enabled) assert.equal(fs.readFileSync(path.join(temporary, "app-host-products/app-host-products.aar"), "utf8"), "opaque product and producer log");
    });
  }
}
