// Local dev refuses to start when a web env file carries production markers.
// Fake ids and fake values only; no output may contain a value.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const DEV_ID = "00000000-fake-0000-0000-00000000dev0";
const PROD_ID = "99999999-fake-9999-9999-9999999prod9";
const SECRET = "FAKE-SECRET-VALUE-do-not-print-7f3a";

function sourceWith(files, extraEnv = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-dev-env-guard-"));
  try {
    const web = path.join(root, "web");
    mkdirSync(path.join(web, "scripts"), { recursive: true });
    // Run the real scripts from a copy, so the web dir is the fixture.
    for (const name of ["load-dev-env.sh", "check-dev-env-files.sh"]) {
      const source = path.join(scriptsDir, name);
      if (existsSync(source)) copyFileSync(source, path.join(web, "scripts", name));
    }
    const secrets = path.join(root, "home", ".secrets");
    mkdirSync(secrets, { recursive: true });
    const devSecrets = path.join(secrets, "cmuxterm-dev.env");
    writeFileSync(devSecrets, `NEXT_PUBLIC_STACK_PROJECT_ID=${DEV_ID}\nSTACK_SECRET_SERVER_KEY=${SECRET}-dev\n`, {
      mode: 0o600,
    });
    for (const [name, text] of Object.entries(files)) {
      writeFileSync(path.join(web, name), text, { mode: 0o600 });
    }
    const result = spawnSync("bash", ["-c", 'source "$1"', "bash", path.join(web, "scripts", "load-dev-env.sh")], {
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: path.join(root, "home"),
        CMUXTERM_ENV_FILE: devSecrets,
        CMUXTERM_EXTRA_ENV_FILE: "",
        CMUX_WEB_EXTRA_ENV_FILE: "",
        CMUX_ALLOW_NONDEV_ENV_FILES: "",
        ...extraEnv,
      },
    });
    for (const stream of [result.stdout, result.stderr]) {
      assert.ok(!stream.includes(SECRET), "a secret value was printed");
      assert.ok(!stream.includes(PROD_ID), "a project id value was printed");
      assert.ok(!stream.includes("rds.amazonaws.com"), "a host value was printed");
    }
    return result;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("no web env files: local dev starts", () => {
  assert.equal(sourceWith({}).status, 0);
});

test("a development env file starts", () => {
  const result = sourceWith({
    ".env.local": `NEXT_PUBLIC_STACK_PROJECT_ID="${DEV_ID}"\nPGHOST=localhost\nDATABASE_URL=postgres://u:${SECRET}@127.0.0.1:5432/x\nVERCEL_OIDC_TOKEN=${SECRET}\nVERCEL_ENV=development\n`,
  });
  assert.equal(result.status, 0, result.stderr);
});

const markers = {
  NEXT_PUBLIC_STACK_PROJECT_ID: `NEXT_PUBLIC_STACK_PROJECT_ID="${PROD_ID}"\n`,
  STACK_PROJECT_ID: `export STACK_PROJECT_ID='${PROD_ID}'\n`,
  VERCEL_ENV: "VERCEL_ENV=\"production\"\n",
  VERCEL_TARGET_ENV: "VERCEL_TARGET_ENV=preview\n",
  PGHOST: "PGHOST=prod.cluster-fake.us-west-2.rds.amazonaws.com\n",
  DATABASE_URL: `DATABASE_URL=postgres://u:${SECRET}@prod.cluster-fake.rds.amazonaws.com:5432/x\n`,
  POSTGRES_URL: `POSTGRES_URL="postgresql://u:${SECRET}@10.2.3.4/x"\n`,
};

for (const [key, line] of Object.entries(markers)) {
  for (const file of [".env.local", ".env.development.local", ".env"]) {
    test(`${key} in ${file} stops local dev and names only the key`, () => {
      const result = sourceWith({ [file]: line });
      assert.notEqual(result.status, 0, `${key} in ${file} was accepted`);
      assert.match(result.stderr, new RegExp(key));
    });
  }
}

test("a Stack id with no dev reference id fails closed", () => {
  const result = sourceWith(
    { ".env.local": `NEXT_PUBLIC_STACK_PROJECT_ID=${DEV_ID}\n` },
    { CMUXTERM_ENV_FILE: "/nonexistent/cmuxterm-dev.env", HOME: "/nonexistent-home" },
  );
  assert.notEqual(result.status, 0);
});

test("the human bypass skips the check", () => {
  const result = sourceWith({ ".env.local": markers.VERCEL_ENV }, { CMUX_ALLOW_NONDEV_ENV_FILES: "1" });
  assert.equal(result.status, 0, result.stderr);
});
