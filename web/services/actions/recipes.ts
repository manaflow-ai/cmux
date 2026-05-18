import { createHash } from "node:crypto";

export type ActionRunMode = "full" | "basic";

export type ActionRecipeInput = {
  readonly ref: string;
  readonly mode: ActionRunMode;
};

export type ActionPort = {
  readonly name: string;
  readonly port: number;
  readonly url: string;
};

export type ActionRecipe = {
  readonly id: string;
  readonly title: string;
  readonly repoUrl: string;
  readonly defaultRef: string;
  readonly cacheVersion: string;
  readonly setupTimeoutMs: number;
  readonly startTimeoutMs: number;
  readonly ports: readonly ActionPort[];
  cacheName(input: ActionRecipeInput & { readonly baseImage: string }): string;
  setupScript(input: ActionRecipeInput): string;
  startScript(input: ActionRecipeInput): string;
};

const STACK_AUTH_ACTION_ID = "hexclave/stack-auth:fresh-env";
const STACK_AUTH_REPO_URL = "https://github.com/hexclave/stack-auth.git";
const STACK_AUTH_DEFAULT_REF = "dev";
const STACK_AUTH_CACHE_VERSION = "20260518b";
const STACK_AUTH_WORKDIR = "/workspace/stack-auth";
const STACK_AUTH_PNPM_VERSION = "10.23.0";
const STACK_AUTH_PORT_PREFIX = "81";

export function actionRecipe(id: string): ActionRecipe | null {
  switch (id) {
    case STACK_AUTH_ACTION_ID:
      return stackAuthFreshEnvRecipe;
    default:
      return null;
  }
}

export function normalizeActionRunMode(raw: unknown): ActionRunMode {
  return raw === "basic" ? "basic" : "full";
}

export function normalizeActionRef(raw: unknown, fallback: string): string {
  if (typeof raw !== "string") return fallback;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : fallback;
}

export const stackAuthFreshEnvRecipe: ActionRecipe = {
  id: STACK_AUTH_ACTION_ID,
  title: "Fresh Stack Auth environment",
  repoUrl: STACK_AUTH_REPO_URL,
  defaultRef: STACK_AUTH_DEFAULT_REF,
  cacheVersion: STACK_AUTH_CACHE_VERSION,
  setupTimeoutMs: 15 * 60 * 1000,
  startTimeoutMs: 15 * 60 * 1000,
  ports: [
    { name: "Launchpad", port: 8100, url: "http://localhost:8100" },
    { name: "Dashboard", port: 8101, url: "http://localhost:8101" },
    { name: "Backend", port: 8102, url: "http://localhost:8102" },
  ],
  cacheName(input) {
    const key = cacheKey([
      "cmux-actions",
      STACK_AUTH_ACTION_ID,
      STACK_AUTH_CACHE_VERSION,
      input.baseImage,
      STACK_AUTH_REPO_URL,
      STACK_AUTH_DEFAULT_REF,
      `pnpm@${STACK_AUTH_PNPM_VERSION}`,
      "docker",
      "devcontainer-lifecycle:v1",
    ]);
    return `cmux-actions-stack-auth-${key}`;
  },
  setupScript() {
    return shellScript([
      ...baseEnvironmentCommands(),
      ...dockerCommands(),
      ...pnpmCommands(),
      ...checkoutCommands(STACK_AUTH_DEFAULT_REF),
      ...devcontainerCommandSupport(),
      runDevcontainerCommandOrFallback("postCreateCommand", [
        "pnpm install --frozen-lockfile",
        "pnpm build:packages",
        "pnpm codegen",
        "pnpm run start-deps",
        "pnpm run stop-deps",
      ]),
      "docker image ls >/workspace/.cmux-actions/docker-images.txt",
    ]);
  },
  startScript(input) {
    const devCommand = input.mode === "basic" ? "pnpm run dev:basic" : "pnpm run dev:named";
    const waitTargets = input.mode === "basic"
      ? ["http://localhost:8101", "http://localhost:8102"]
      : ["http://localhost:8100", "http://localhost:8101", "http://localhost:8102"];
    return shellScript([
      ...baseEnvironmentCommands(),
      ...dockerCommands(),
      ...pnpmCommands(),
      ...checkoutCommands(input.ref),
      ...devcontainerCommandSupport(),
      runDevcontainerCommandOrFallback("postStartCommand", [
        "pnpm install --frozen-lockfile --prefer-offline",
      ]),
      runDevcontainerCommandOrFallback("postAttachCommand", []),
      "pnpm run start-deps",
      "mkdir -p /workspace/.cmux-actions/logs",
      [
        "if ! pgrep -af 'stack-named-dev-server|turbo run dev|next dev' >/dev/null 2>&1; then",
        `  nohup bash -lc ${shellQuote(`cd ${STACK_AUTH_WORKDIR} && export NEXT_PUBLIC_STACK_PORT_PREFIX=${STACK_AUTH_PORT_PREFIX} && ${devCommand}`)} >/workspace/.cmux-actions/logs/dev.log 2>&1 &`,
        "fi",
      ].join("\n"),
      `pnpm exec wait-on ${waitTargets.map(shellQuote).join(" ")} --timeout 180000`,
    ]);
  },
};

function baseEnvironmentCommands(): string[] {
  return [
    "export DEBIAN_FRONTEND=noninteractive",
    "export TERM=xterm-256color",
    `export NEXT_PUBLIC_STACK_PORT_PREFIX=${shellQuote(STACK_AUTH_PORT_PREFIX)}`,
    "mkdir -p /workspace/.cmux-actions/logs",
  ];
}

function dockerCommands(): string[] {
  return [
    [
      "if ! command -v docker >/dev/null 2>&1; then",
      "  apt-get update",
      "  apt-get install -y --no-install-recommends docker.io docker-compose-v2",
      "  rm -rf /var/lib/apt/lists/*",
      "fi",
    ].join("\n"),
    [
      "if ! docker info >/dev/null 2>&1; then",
      "  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then",
      "    systemctl enable docker >/dev/null 2>&1 || true",
      "    systemctl start docker >/dev/null",
      "    systemctl is-active --quiet docker",
      "  elif command -v service >/dev/null 2>&1; then",
      "    service docker start >/dev/null",
      "  else",
      "    echo 'Docker cannot be started because this VM has no supported service manager.' >&2",
      "    exit 1",
      "  fi",
      "fi",
      "test -S /var/run/docker.sock",
    ].join("\n"),
    "docker info >/dev/null",
    "docker compose version >/dev/null",
  ];
}

function pnpmCommands(): string[] {
  return [
    "if ! command -v corepack >/dev/null 2>&1; then npm install -g --omit=dev --no-audit --fund=false corepack@latest; fi",
    "corepack enable",
    `corepack prepare pnpm@${STACK_AUTH_PNPM_VERSION} --activate`,
    `test "$(pnpm --version)" = ${shellQuote(STACK_AUTH_PNPM_VERSION)}`,
  ];
}

function checkoutCommands(ref: string): string[] {
  const quotedRef = shellQuote(ref);
  return [
    "mkdir -p /workspace",
    [
      `if [ ! -d ${shellQuote(`${STACK_AUTH_WORKDIR}/.git`)} ]; then`,
      `  git clone --depth 1 --branch ${quotedRef} ${shellQuote(STACK_AUTH_REPO_URL)} ${shellQuote(STACK_AUTH_WORKDIR)} || git clone ${shellQuote(STACK_AUTH_REPO_URL)} ${shellQuote(STACK_AUTH_WORKDIR)}`,
      "fi",
    ].join("\n"),
    `cd ${shellQuote(STACK_AUTH_WORKDIR)}`,
    `git remote set-url origin ${shellQuote(STACK_AUTH_REPO_URL)}`,
    `git fetch origin ${quotedRef} --depth 1 || git fetch origin ${quotedRef}`,
    "git checkout -B cmux-actions-run FETCH_HEAD",
    "git reset --hard FETCH_HEAD",
    "git clean -ffd",
  ];
}

function devcontainerCommandSupport(): string[] {
  return [
    [
      "cat >/workspace/.cmux-actions/read-devcontainer-command.mjs <<'NODE'",
      "import fs from 'node:fs';",
      "",
      "const [key, outputPath] = process.argv.slice(2);",
      "const configPath = '.devcontainer/devcontainer.json';",
      "if (!key || !outputPath) process.exit(1);",
      "if (!fs.existsSync(configPath)) process.exit(2);",
      "const config = JSON.parse(stripJsonc(fs.readFileSync(configPath, 'utf8')));",
      "const raw = config[key];",
      "if (raw === undefined || raw === null || raw === false) process.exit(2);",
      "",
      "function commandLines(value) {",
      "  if (typeof value === 'string') return [value];",
      "  if (Array.isArray(value) && value.every((item) => typeof item === 'string')) return value;",
      "  if (typeof value === 'object' && !Array.isArray(value)) {",
      "    const values = Object.values(value);",
      "    if (values.every((item) => typeof item === 'string')) return values;",
      "  }",
      "  throw new Error(`${key} must be a string, string array, or string map`);",
      "}",
      "",
      "const lines = commandLines(raw);",
      "if (lines.length === 0) process.exit(2);",
      "fs.writeFileSync(outputPath, ['set -eo pipefail', ...lines].join('\\n') + '\\n');",
      "",
      "function stripJsonc(source) {",
      "  const withoutComments = stripComments(source);",
      "  return stripTrailingCommas(withoutComments);",
      "}",
      "",
      "function stripComments(source) {",
      "  let output = '';",
      "  let inString = false;",
      "  let escaped = false;",
      "  for (let i = 0; i < source.length; i++) {",
      "    const ch = source[i];",
      "    const next = source[i + 1];",
      "    if (inString) {",
      "      output += ch;",
      "      if (escaped) { escaped = false; continue; }",
      "      if (ch === '\\\\') { escaped = true; continue; }",
      "      if (ch === '\"') inString = false;",
      "      continue;",
      "    }",
      "    if (ch === '\"') { inString = true; output += ch; continue; }",
      "    if (ch === '/' && next === '/') {",
      "      while (i < source.length && source[i] !== '\\n') i++;",
      "      output += '\\n';",
      "      continue;",
      "    }",
      "    if (ch === '/' && next === '*') {",
      "      i += 2;",
      "      while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) i++;",
      "      if (i >= source.length - 1) throw new Error('unterminated block comment');",
      "      output += ' ';",
      "      i++;",
      "      continue;",
      "    }",
      "    output += ch;",
      "  }",
      "  return output;",
      "}",
      "",
      "function stripTrailingCommas(source) {",
      "  let output = '';",
      "  let inString = false;",
      "  let escaped = false;",
      "  for (let i = 0; i < source.length; i++) {",
      "    const ch = source[i];",
      "    if (inString) {",
      "      output += ch;",
      "      if (escaped) { escaped = false; continue; }",
      "      if (ch === '\\\\') { escaped = true; continue; }",
      "      if (ch === '\"') inString = false;",
      "      continue;",
      "    }",
      "    if (ch === '\"') { inString = true; output += ch; continue; }",
      "    if (ch === ',') {",
      "      let j = i + 1;",
      "      while (j < source.length && /\\s/.test(source[j])) j++;",
      "      if (source[j] === '}' || source[j] === ']') continue;",
      "    }",
      "    output += ch;",
      "  }",
      "  return output;",
      "}",
      "NODE",
    ].join("\n"),
  ];
}

function runDevcontainerCommandOrFallback(key: string, fallback: readonly string[]): string {
  const outputPath = `/workspace/.cmux-actions/devcontainer-${key}.sh`;
  const fallbackBlock = fallback.length > 0 ? fallback.join("\n") : "true";
  return [
    `if node /workspace/.cmux-actions/read-devcontainer-command.mjs ${shellQuote(key)} ${shellQuote(outputPath)}; then`,
    `  echo "Running devcontainer ${key}"`,
    `  . ${shellQuote(outputPath)}`,
    "else",
    "  status=$?",
    "  if [ \"$status\" -eq 2 ]; then",
    indentShell(fallbackBlock, "    "),
    "  else",
    "    exit \"$status\"",
    "  fi",
    "fi",
  ].join("\n");
}

function shellScript(commands: readonly string[]): string {
  return [
    "set -euo pipefail",
    ...commands,
  ].join("\n");
}

function cacheKey(parts: readonly string[]): string {
  const hash = createHash("sha256");
  for (const part of parts) {
    hash.update(part);
    hash.update("\0");
  }
  return hash.digest("hex").slice(0, 20);
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function indentShell(value: string, indent: string): string {
  return value
    .split("\n")
    .map((line) => `${indent}${line}`)
    .join("\n");
}
