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
  const ast = new Parser(new Lexer(expression).lex().tokens, Object.keys(values), []).parse();
  return new Evaluator(ast, context(values)).evaluate().coerceString();
}
function render(expression, values) {
  return expression.replace(/\$\{\{([\s\S]*?)\}\}/g, (_, code) => evaluate(code, values));
}

for (const jobName of ["app-host-unit-tests", "tests-build-and-lag"]) {
  for (const enabled of [true, false]) {
    test(`${jobName}: actual workflow selects ${enabled ? "authenticated verified R2 bytes" : "measured GitHub fallback"}`, (t) => {
      const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-artifact-workflow-"));
      t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
      const bin = path.join(temporary, "bin");
      fs.mkdirSync(bin);
      const stub = `#!/usr/bin/env python3
import hashlib, json, os, pathlib, stat, sys, zipfile
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
    args = sys.argv[1:]
    config = pathlib.Path(args[args.index("--config") + 1])
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
    assert "oidc-request-token" not in args
    assert "header.payload.signature" not in args
    url = args[-1]
    if url.startswith("https://token.actions.githubusercontent.com/oidc?"):
        assert "audience=cmux-ci-artifacts" in url
        assert "Authorization: Bearer oidc-request-token" in config.read_text()
        (work / "oidc-called").touch()
        print(json.dumps({"value":"header.payload.signature"}))
    else:
        assert url == "https://broker.example/v1/manaflow-ai/cmux/artifacts/123/"+hashlib.sha256(blob).hexdigest()+".zip"
        assert "Authorization: Bearer header.payload.signature" in config.read_text()
        target = pathlib.Path(args[args.index("--output") + 1])
        headers = pathlib.Path(args[args.index("--dump-header") + 1])
        target.write_bytes(blob)
        headers.write_text("HTTP/1.1 200 OK\\r\\nX-Cmux-Artifact-Cache: fill\\r\\n\\r\\n")
        (work / "broker-called").touch()
        print(f"200 0.100 0.500 {len(blob)}", end="")
`;
      for (const command of ["gh", "curl"]) fs.writeFileSync(path.join(bin, command), stub, { mode: 0o755 });
      const job = workflow.jobs[jobName];
      assert.equal(job.permissions.actions, "read");
      assert.equal(job.permissions.contents, "read");
      assert.equal(job.permissions["id-token"], "write");

      const restore = job.steps.find((step) => step.id === "r2-products");
      const fallback = job.steps.find((step) => step.name === "Download compiled app-host test product");
      const values = {
        github: { token: "read-only-job-token" },
        vars: { CI_ARTIFACT_R2_URL: enabled ? "https://broker.example" : "" },
        needs: { "macos-compile-admission": { outputs: { artifact_id: "123" } } },
      };
      const output = path.join(temporary, "output");
      execFileSync("bash", ["-e", "-c", restore.run], { cwd: root, env: {
        ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: temporary,
        GITHUB_OUTPUT: output, GITHUB_RUN_ID: "456", GITHUB_RUN_ATTEMPT: "1",
        GITHUB_REPOSITORY: "manaflow-ai/cmux",
        ACTIONS_ID_TOKEN_REQUEST_URL: "https://token.actions.githubusercontent.com/oidc?api-version=2.0",
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: "oidc-request-token",
        ...Object.fromEntries(Object.entries(restore.env).map(([key, value]) => [key, render(value, values)])),
      } });

      const outputs = Object.fromEntries(fs.readFileSync(output, "utf8").trim().split("\n").map((line) => line.split("=", 2)));
      assert.equal(outputs.hit, enabled ? "true" : "false");
      assert.equal(outputs.route, enabled ? "r2" : "github");
      assert.equal(outputs.r2_result, enabled ? "fill" : "disabled");

      const downloadFallback = evaluate(fallback.if, { steps: { "r2-products": { outputs: { hit: outputs.hit } } } }) === "true";
      assert.equal(downloadFallback, !enabled);
      assert.equal(fallback.uses, "./.github/actions/download-test-product");
      assert.equal(render(fallback.with["artifact-id"], values), "123");

      assert.equal(fs.existsSync(path.join(temporary, "metadata-called")), enabled);
      assert.equal(fs.existsSync(path.join(temporary, "oidc-called")), enabled);
      assert.equal(fs.existsSync(path.join(temporary, "broker-called")), enabled);
      if (enabled) {
        assert.equal(fs.readFileSync(path.join(temporary, "app-host-products/app-host-products.aar"), "utf8"),
          "opaque product and producer log");
      }
    });
  }
}
