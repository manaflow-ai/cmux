// Replay engine for cmux dev environment profiles (P3 of turnkey dev builds).
//
// A profile is a JSON file under scripts/dev-profiles/<name>.json: an ordered
// list of debug-CLI steps that provision a realistic test environment against a
// TAGGED dev cmux instance. Every step is replayed through
// `scripts/cmux-debug-cli.sh`, which refuses without `CMUX_TAG` and targets
// `/tmp/cmux-debug-<slug>.sock` (never the user's stable app).
//
// Profile format (one file per profile, JSON):
//
//   {
//     "description": "human summary (optional)",
//     "steps": [
//       { "args": ["workspace", "create", "--name", "Composer",
//                  "--cwd", "${cwd}", "--command", "claude", "--json"],
//         "capture": { "ws": "workspace_id" } },
//       { "args": ["send", "--workspace", "${ws}", "echo hi\\n"] }
//     ]
//   }
//
// - `args` is the exact `cmux` argument vector for that step (no leading `cmux`).
// - `${name}` placeholders are substituted from earlier captures and the small
//   built-in variable set (currently `${cwd}` = the directory dev-setup ran in,
//   overridable via the `cwd` context value).
// - `capture` maps a local variable name -> a dotted JSON path read from that
//   step's stdout (the step must pass `--json`). Later steps reference it as
//   `${name}`. Captured values are cmux refs/ids, never secrets.
//
// The construction half (`resolveSteps`) is a pure function of (profile, context)
// with no I/O, so it is unit-testable without a live socket
// (`node --test scripts/dev-profiles/replay.test.mjs`). `ProfileReplayer`
// wraps it with execution against the tagged CLI.
//
// Adding a profile = adding a JSON file. See scripts/dev-profiles/README.md.

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const PLACEHOLDER_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g;

/**
 * Substitute `${name}` placeholders in a single argument string.
 *
 * @param {string} arg A raw argument from a step's `args` vector.
 * @param {Record<string, string>} vars Known variable name -> value.
 * @returns {string} The argument with every placeholder replaced.
 * @throws {Error} When a referenced variable is undefined.
 */
export function substituteArg(arg, vars) {
  return arg.replace(PLACEHOLDER_RE, (_match, name) => {
    if (!Object.prototype.hasOwnProperty.call(vars, name)) {
      throw new Error(
        `profile step references undefined variable \${${name}} ` +
          `(known: ${Object.keys(vars).join(", ") || "none"})`,
      );
    }
    return vars[name];
  });
}

/**
 * Read a dotted path (e.g. `group.id`) out of a parsed JSON object.
 *
 * @param {unknown} obj The parsed JSON value.
 * @param {string} dottedPath A `.`-separated path.
 * @returns {unknown} The value at that path, or `undefined` if any hop misses.
 */
export function readJSONPath(obj, dottedPath) {
  return dottedPath.split(".").reduce((acc, key) => {
    if (acc && typeof acc === "object" && key in acc) {
      return acc[key];
    }
    return undefined;
  }, obj);
}

/**
 * Validate a profile object's shape, returning its normalized steps.
 *
 * @param {unknown} profile A parsed profile JSON value.
 * @param {string} [label] A name used in error messages.
 * @returns {Array<{args: string[], capture?: Record<string, string>}>}
 * @throws {Error} When the profile is malformed.
 */
export function validateProfile(profile, label = "profile") {
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) {
    throw new Error(`${label}: expected a JSON object`);
  }
  const steps = profile.steps;
  if (!Array.isArray(steps) || steps.length === 0) {
    throw new Error(`${label}: "steps" must be a non-empty array`);
  }
  steps.forEach((step, i) => {
    if (!step || typeof step !== "object" || Array.isArray(step)) {
      throw new Error(`${label}: step ${i} must be an object`);
    }
    if (!Array.isArray(step.args) || step.args.length === 0) {
      throw new Error(`${label}: step ${i} needs a non-empty "args" array`);
    }
    if (!step.args.every((a) => typeof a === "string")) {
      throw new Error(`${label}: step ${i} "args" must be all strings`);
    }
    if (step.capture !== undefined) {
      if (
        !step.capture ||
        typeof step.capture !== "object" ||
        Array.isArray(step.capture)
      ) {
        throw new Error(`${label}: step ${i} "capture" must be an object`);
      }
      for (const [k, v] of Object.entries(step.capture)) {
        if (typeof v !== "string") {
          throw new Error(
            `${label}: step ${i} capture "${k}" must map to a string JSON path`,
          );
        }
      }
      if (!step.args.includes("--json")) {
        throw new Error(
          `${label}: step ${i} declares "capture" but its args omit "--json"; ` +
            `capture reads the step's JSON stdout`,
        );
      }
    }
  });
  return steps;
}

/**
 * Resolve a profile into the concrete `cmux` argument vectors that would run,
 * given a set of starting context variables (e.g. `${cwd}`).
 *
 * This is the pure, I/O-free half of the engine. It substitutes every
 * placeholder it can from the context, but it cannot fill captured variables
 * (those depend on live step output). For `--dry-run` and for unit tests, pass
 * the captures you expect via `context` to see the fully-resolved vectors;
 * otherwise unresolved captures surface as a thrown error naming the variable.
 *
 * @param {{steps: Array<object>}} profile A parsed, validated profile.
 * @param {Record<string, string>} [context] Starting variables.
 * @returns {Array<{argv: string[], capture?: Record<string, string>}>}
 *   One entry per step with its substituted argument vector.
 */
export function resolveSteps(profile, context = {}) {
  const steps = validateProfile(profile);
  const vars = { ...context };
  return steps.map((step) => {
    const argv = step.args.map((a) => substituteArg(a, vars));
    // Pre-declare captured names so a later-resolving dry run still substitutes
    // the placeholder (with the literal capture token) instead of throwing.
    if (step.capture) {
      for (const name of Object.keys(step.capture)) {
        if (!(name in vars)) {
          vars[name] = `<captured:${name}>`;
        }
      }
    }
    return { argv, capture: step.capture };
  });
}

/**
 * Discover the available profile names (filenames without `.json`) in a dir.
 *
 * @param {string} dir The `scripts/dev-profiles` directory.
 * @returns {string[]} Sorted profile names.
 */
export function listProfiles(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => f.replace(/\.json$/, ""))
    .sort();
}

/**
 * Load and validate a profile by name from a directory.
 *
 * @param {string} dir The `scripts/dev-profiles` directory.
 * @param {string} name The profile name (no extension).
 * @returns {{steps: Array<object>, description?: string}}
 * @throws {Error} When the file is missing or malformed (lists alternatives).
 */
export function loadProfile(dir, name) {
  const file = path.join(dir, `${name}.json`);
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    const available = listProfiles(dir);
    throw new Error(
      `unknown profile "${name}". Available: ${available.join(", ") || "(none)"}`,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`profile "${name}" is not valid JSON: ${err.message}`);
  }
  validateProfile(parsed, `profile "${name}"`);
  return parsed;
}

/**
 * Executes resolved profile steps against a tagged dev cmux socket.
 *
 * Each step shells out to `scripts/cmux-debug-cli.sh` with `CMUX_TAG` set, so
 * the safety contract (refuse without a tag, target the tagged socket only) is
 * enforced by the helper, not re-implemented here.
 */
export class ProfileReplayer {
  /**
   * @param {object} opts
   * @param {string} opts.tag The `CMUX_TAG` value (tagged dev build).
   * @param {string} opts.cliPath Absolute path to `scripts/cmux-debug-cli.sh`.
   * @param {Record<string, string>} [opts.context] Starting variables.
   * @param {(msg: string) => void} [opts.log] Progress logger (stderr).
   */
  constructor({ tag, cliPath, context = {}, log = () => {} }) {
    this.tag = tag;
    this.cliPath = cliPath;
    this.vars = { ...context };
    this.log = log;
  }

  /**
   * Replay one already-substituted step, applying its captures to `this.vars`.
   *
   * @param {{argv: string[], capture?: Record<string, string>}} step
   * @returns {{stdout: string}}
   * @throws {Error} When the CLI call fails or a capture path is absent.
   */
  runStep(step) {
    const display = step.argv.join(" ");
    this.log(`  cmux ${display}`);
    const res = spawnSync(this.cliPath, step.argv, {
      encoding: "utf8",
      env: { ...process.env, CMUX_TAG: this.tag, CMUX_QUIET: "1" },
    });
    if (res.error) {
      throw new Error(`failed to spawn debug CLI: ${res.error.message}`);
    }
    if (res.status !== 0) {
      const detail = (res.stderr || res.stdout || "").trim();
      throw new Error(`step failed (exit ${res.status}): cmux ${display}\n${detail}`);
    }
    const stdout = res.stdout || "";
    if (step.capture) {
      let parsed;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        throw new Error(
          `step declared captures but stdout was not JSON: cmux ${display}`,
        );
      }
      for (const [name, jsonPath] of Object.entries(step.capture)) {
        const value = readJSONPath(parsed, jsonPath);
        if (value === undefined || value === null) {
          throw new Error(
            `capture "${name}" path "${jsonPath}" not found in output of: cmux ${display}`,
          );
        }
        this.vars[name] = String(value);
      }
    }
    return { stdout };
  }

  /**
   * Resolve + replay every step of a profile in order.
   *
   * Substitution happens per-step so captures from earlier steps are visible
   * to later ones.
   *
   * @param {{steps: Array<object>}} profile A validated profile.
   */
  run(profile) {
    const steps = validateProfile(profile);
    for (const step of steps) {
      const argv = step.args.map((a) => substituteArg(a, this.vars));
      this.runStep({ argv, capture: step.capture });
    }
  }
}
