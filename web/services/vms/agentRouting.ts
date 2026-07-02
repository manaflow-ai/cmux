import { createHash } from "node:crypto";

/**
 * Per-user subrouter agent routing for Cloud VMs.
 *
 * Subrouter (github.com/manaflow-ai/subrouter) is an LLM proxy with a
 * multi-tenant mode where a tenant is addressed by base URLs of the form
 * `<serverUrl>/t/<tenant-key>` (Anthropic paths), `<serverUrl>/t/<tenant-key>/v1`
 * (Codex/OpenAI), and `<serverUrl>/t/<tenant-key>/backend-api` (ChatGPT backend).
 *
 * This module owns the pure parts: request validation, tenant-key masking, and
 * generation of the idempotent in-VM ensure script that the Freestyle attach
 * path executes. Database access lives in the VM repository; the workflow layer
 * wires the two together.
 *
 * The tenant key is a secret. It appears only inside the base64-encoded ensure
 * script sent to the VM and in files it writes there; it must never be logged
 * or returned in full from GET endpoints.
 */

export type AgentRoutingConfig = {
  readonly subrouterUrl: string;
  readonly subrouterTenantKey: string;
};

const SUBROUTER_URL_MAX_LENGTH = 2048;
const TENANT_KEY_MIN_LENGTH = 8;
const TENANT_KEY_MAX_LENGTH = 512;
// The tenant key is embedded in a URL path segment (`/t/<key>`), so restrict it
// to unreserved URL characters. This also keeps it safe inside the generated
// shell/python/TOML/JSON content without escaping surprises.
const TENANT_KEY_PATTERN = /^[A-Za-z0-9._~-]+$/;

export type AgentRoutingValidation =
  | { readonly ok: true; readonly value: string }
  | { readonly ok: false; readonly message: string };

export function validateSubrouterUrl(raw: unknown): AgentRoutingValidation {
  if (typeof raw !== "string") {
    return { ok: false, message: "subrouterUrl must be a string" };
  }
  const trimmed = raw.trim().replace(/\/+$/u, "");
  if (!trimmed) {
    return { ok: false, message: "subrouterUrl must not be empty" };
  }
  if (trimmed.length > SUBROUTER_URL_MAX_LENGTH) {
    return { ok: false, message: `subrouterUrl must be at most ${SUBROUTER_URL_MAX_LENGTH} characters` };
  }
  if (/\s/u.test(trimmed)) {
    return { ok: false, message: "subrouterUrl must not contain whitespace" };
  }
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return { ok: false, message: "subrouterUrl must be a valid URL" };
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return { ok: false, message: "subrouterUrl must use http or https" };
  }
  if (!parsed.hostname) {
    return { ok: false, message: "subrouterUrl must include a host" };
  }
  if (parsed.username || parsed.password) {
    return { ok: false, message: "subrouterUrl must not embed credentials" };
  }
  if (parsed.search || parsed.hash) {
    return { ok: false, message: "subrouterUrl must not include a query string or fragment" };
  }
  return { ok: true, value: trimmed };
}

export function validateSubrouterTenantKey(raw: unknown): AgentRoutingValidation {
  if (typeof raw !== "string") {
    return { ok: false, message: "subrouterTenantKey must be a string" };
  }
  const trimmed = raw.trim();
  if (!trimmed) {
    return { ok: false, message: "subrouterTenantKey must not be empty" };
  }
  if (trimmed.length < TENANT_KEY_MIN_LENGTH || trimmed.length > TENANT_KEY_MAX_LENGTH) {
    return {
      ok: false,
      message: `subrouterTenantKey must be ${TENANT_KEY_MIN_LENGTH}-${TENANT_KEY_MAX_LENGTH} characters`,
    };
  }
  if (!TENANT_KEY_PATTERN.test(trimmed)) {
    return {
      ok: false,
      message: "subrouterTenantKey may only contain letters, numbers, dot, underscore, tilde, and dash",
    };
  }
  return { ok: true, value: trimmed };
}

/** `srt_abcdef1234` -> `srt_ab...34`. Never reveals more than 8 characters. */
export function maskTenantKey(key: string): string {
  if (key.length < 12) {
    return `${key.slice(0, 2)}...`;
  }
  return `${key.slice(0, 6)}...${key.slice(-2)}`;
}

export function subrouterTenantBaseUrl(config: AgentRoutingConfig): string {
  const base = config.subrouterUrl.replace(/\/+$/u, "");
  return `${base}/t/${config.subrouterTenantKey}`;
}

const AGENT_ROUTING_STATE_PATH = "/etc/cmux/agent-routing.state";
const AGENT_ENV_PATH = "/etc/cmux/agent-env.sh";
const ZSHRC_PATH = "/etc/cmux/zshrc";
const MANAGED_BEGIN = "# >>> cmux-agent-routing >>>";
const MANAGED_END = "# <<< cmux-agent-routing <<<";
const SCRIPT_VERSION = "v1";

export function agentRoutingStateToken(config: AgentRoutingConfig | null): string {
  if (!config) return `removed:${SCRIPT_VERSION}`;
  const hash = createHash("sha256")
    .update(`${SCRIPT_VERSION}\n${config.subrouterUrl}\n${config.subrouterTenantKey}`)
    .digest("hex");
  return `applied:${SCRIPT_VERSION}:${hash}`;
}

function agentEnvFileContents(config: AgentRoutingConfig): string {
  const tenantBase = subrouterTenantBaseUrl(config);
  return [
    "# cmux-agent-routing (managed by cmux; do not edit, changes are overwritten)",
    `export ANTHROPIC_BASE_URL='${tenantBase}'`,
    `export ANTHROPIC_AUTH_TOKEN='${config.subrouterTenantKey}'`,
    "",
  ].join("\n");
}

/**
 * Python helper that merges the cmux-managed agent-routing keys into
 * `~/.codex/config.toml` (marker-delimited block prepended so the keys stay
 * top-level) and `~/.claude/settings.json` (JSON env merge), preserving all
 * unrelated user content. `mode` is baked in: "apply" writes the managed
 * values, "remove" strips them. Exported so tests can run the real merge
 * against a temp directory (CMUX_AGENT_ROUTING_HOME is a test-only override;
 * in the VM it is unset and the helper targets /home/cmux).
 */
export function buildAgentRoutingMergeScript(config: AgentRoutingConfig | null): string {
  const tenantBase = config ? subrouterTenantBaseUrl(config) : "";
  const tenantKey = config ? config.subrouterTenantKey : "";
  const mode = config ? "apply" : "remove";
  return `import json, os, re

MODE = ${JSON.stringify(mode)}
TENANT_BASE = ${JSON.stringify(tenantBase)}
TENANT_KEY = ${JSON.stringify(tenantKey)}
HOME = os.environ.get("CMUX_AGENT_ROUTING_HOME", "/home/cmux")
BEGIN = ${JSON.stringify(MANAGED_BEGIN)}
END = ${JSON.stringify(MANAGED_END)}


def chown_cmux(path):
    try:
        import pwd
        record = pwd.getpwnam("cmux")
        os.chown(path, record.pw_uid, record.pw_gid)
    except Exception:
        pass


def write_file(path, contents, mode=0o600):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    chown_cmux(directory)
    with open(path, "w") as handle:
        handle.write(contents)
    os.chmod(path, mode)
    chown_cmux(path)


def update_codex_config():
    path = os.path.join(HOME, ".codex/config.toml")
    existing = ""
    if os.path.exists(path):
        with open(path) as handle:
            existing = handle.read()
    block_pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\\n?", re.S)
    stripped = block_pattern.sub("", existing)
    if MODE == "apply":
        # Drop pre-existing top-level assignments of the keys we manage so the
        # prepended managed block never produces duplicate TOML keys. Only lines
        # before the first table header are top-level.
        lines = stripped.split("\\n")
        kept = []
        seen_table = False
        for line in lines:
            if re.match(r"\\s*\\[", line):
                seen_table = True
            if not seen_table and re.match(r"\\s*(openai_base_url|chatgpt_base_url)\\s*=", line):
                continue
            kept.append(line)
        stripped = "\\n".join(kept)
        block = "\\n".join([
            BEGIN,
            "openai_base_url = " + json.dumps(TENANT_BASE + "/v1"),
            "chatgpt_base_url = " + json.dumps(TENANT_BASE + "/backend-api"),
            END,
            "",
        ])
        updated = block + stripped
    else:
        updated = stripped
    if MODE == "remove" and not existing:
        return
    if updated != existing:
        write_file(path, updated)


def update_claude_settings():
    path = os.path.join(HOME, ".claude/settings.json")
    data = {}
    if os.path.exists(path):
        try:
            with open(path) as handle:
                data = json.load(handle)
        except Exception:
            # Never destroy an unparseable user file. The env vars exported by
            # /etc/cmux/agent-env.sh still cover Claude Code.
            return
        if not isinstance(data, dict):
            return
    elif MODE == "remove":
        return
    env = data.get("env")
    if not isinstance(env, dict):
        env = {}
    if MODE == "apply":
        env["ANTHROPIC_BASE_URL"] = TENANT_BASE
        env["ANTHROPIC_AUTH_TOKEN"] = TENANT_KEY
        data["env"] = env
    else:
        env.pop("ANTHROPIC_BASE_URL", None)
        env.pop("ANTHROPIC_AUTH_TOKEN", None)
        if env:
            data["env"] = env
        else:
            data.pop("env", None)
    write_file(path, json.dumps(data, indent=2) + "\\n")


update_codex_config()
update_claude_settings()
`;
}

function base64(value: string): string {
  return Buffer.from(value, "utf8").toString("base64");
}

/**
 * Idempotent POSIX shell script that converges the VM onto the desired agent
 * routing state. Compare-and-skip: a state token at
 * /etc/cmux/agent-routing.state records what was last applied, so healthy
 * attaches with an unchanged config exit immediately without touching files.
 */
export function buildAgentRoutingEnsureScript(config: AgentRoutingConfig | null): string {
  const stateToken = agentRoutingStateToken(config);
  const python = buildAgentRoutingMergeScript(config);
  const shared = [
    "#!/bin/sh",
    "set -eu",
    `STATE=${shellQuoted(AGENT_ROUTING_STATE_PATH)}`,
    `WANT=${shellQuoted(stateToken)}`,
  ];
  if (config) {
    return [
      ...shared,
      // Fast path: state token matches and the managed pieces are still present.
      `if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$WANT" ] && [ -f ${shellQuoted(AGENT_ENV_PATH)} ] && grep -q ${shellQuoted(MANAGED_BEGIN)} ${shellQuoted(ZSHRC_PATH)} 2>/dev/null; then exit 0; fi`,
      "mkdir -p /etc/cmux",
      "umask 077",
      `printf '%s' '${base64(agentEnvFileContents(config))}' | base64 -d > ${shellQuoted(AGENT_ENV_PATH)}`,
      `chown cmux:cmux ${shellQuoted(AGENT_ENV_PATH)} 2>/dev/null || true`,
      `chmod 600 ${shellQuoted(AGENT_ENV_PATH)}`,
      // Source the env file from the shared zshrc so every PTY session inherits
      // it. Guarded by the managed marker so repeat runs stay idempotent.
      `if ! grep -q ${shellQuoted(MANAGED_BEGIN)} ${shellQuoted(ZSHRC_PATH)} 2>/dev/null; then printf '\\n%s\\n%s\\n%s\\n' ${shellQuoted(MANAGED_BEGIN)} ${shellQuoted(`[ -r ${AGENT_ENV_PATH} ] && . ${AGENT_ENV_PATH}`)} ${shellQuoted(MANAGED_END)} >> ${shellQuoted(ZSHRC_PATH)}; fi`,
      pythonInvocation(python),
      `printf '%s' "$WANT" > "$STATE"`,
      `chmod 600 "$STATE"`,
    ].join("\n");
  }
  return [
    ...shared,
    // Nothing was ever applied and nothing is left to remove.
    `if [ ! -f "$STATE" ] && [ ! -f ${shellQuoted(AGENT_ENV_PATH)} ]; then exit 0; fi`,
    `if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$WANT" ] && [ ! -f ${shellQuoted(AGENT_ENV_PATH)} ]; then exit 0; fi`,
    `rm -f ${shellQuoted(AGENT_ENV_PATH)}`,
    `if [ -f ${shellQuoted(ZSHRC_PATH)} ] && grep -q ${shellQuoted(MANAGED_BEGIN)} ${shellQuoted(ZSHRC_PATH)}; then sed -i '/^# >>> cmux-agent-routing >>>$/,/^# <<< cmux-agent-routing <<<$/d' ${shellQuoted(ZSHRC_PATH)}; fi`,
    pythonInvocation(python),
    "mkdir -p /etc/cmux",
    `printf '%s' "$WANT" > "$STATE"`,
    `chmod 600 "$STATE"`,
  ].join("\n");
}

function pythonInvocation(python: string): string {
  // The python helper handles the structured merges. If python3 is missing
  // (never observed on the cmux Cloud VM image) the env-file wiring above still
  // routes Claude Code via exported env vars; Codex config is skipped rather
  // than corrupted by a text-only merge.
  return [
    "if command -v python3 >/dev/null 2>&1; then",
    `  printf '%s' '${base64(python)}' | base64 -d | python3 -`,
    "fi",
  ].join("\n");
}

/**
 * One-line command for the provider exec API. The script travels base64-encoded
 * so the tenant key never needs shell escaping and never appears in stderr on
 * quoting mistakes.
 */
export function agentRoutingEnsureCommand(config: AgentRoutingConfig | null): string {
  const script = buildAgentRoutingEnsureScript(config);
  return `printf '%s' '${base64(script)}' | base64 -d | sh`;
}

function shellQuoted(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}
