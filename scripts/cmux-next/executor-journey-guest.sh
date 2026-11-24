#!/bin/sh
# executor.sh (npm `executor@beta`, github.com/UsefulSoftwareCo/executor) end to end on one machine, headless:
# install it with its own install script, start its background server, add a keyless MCP source (DeepWiki's public
# MCP server, the docs' own example) as an app, deploy it, and `executor execute` a program that calls one of its
# tools. executor-journey.ts runs this on a cmux Cloud machine over machine exec; it runs the same on any Linux or
# macOS shell:
#
#   EXECUTOR_JOURNEY_HOME=$(mktemp -d) sh scripts/cmux-next/executor-journey-guest.sh
#
# Every phase prints one `EXJ <phase> ok|fail <detail>` line; the last line is `EXJ result <json>` with the job's
# answer, or the script exits nonzero at the first failed phase. The background server it started is stopped at the
# end, pass or fail. EXECUTOR_VERSION pins a release (default: the install script's newest beta).
#
# No browser and no API key are needed: commands without --host use the local background server, which the CLI
# starts and authenticates itself. (`--host http://127.0.0.1:PORT` instead needs EXECUTOR_API_KEY, which no
# command prints; the server keeps it in ~/.executor/v2/cli/keys.json.)
set -u
home="${EXECUTOR_JOURNEY_HOME:-$HOME/.cmux/executor-journey}"
mkdir -p "$home/app" || exit 1
export HOME="$home"
export PATH="$home/.local/bin:$PATH"
export DO_NOT_TRACK=1
ok() { echo "EXJ $1 ok ${2:-}"; }
fail() { echo "EXJ $1 fail ${2:-}"; executor service stop >/dev/null 2>&1; exit 1; }
tail1() { tr '\n' ' ' < "$1" | tail -c 600; }

echo "EXJ host $(uname -sm) $(id -un 2>/dev/null)"
t0=$(date +%s)
if ! curl -fsSL --retry 3 --max-time 60 https://executor.sh/docs/install.sh -o "$home/install.sh" >"$home/dl.log" 2>&1; then
  fail install "download install.sh: $(tail1 "$home/dl.log")"
fi
if ! sh "$home/install.sh" ${EXECUTOR_VERSION:+"$EXECUTOR_VERSION"} >"$home/install.log" 2>&1; then
  fail install "$(tail1 "$home/install.log")"
fi
ok install "$(executor --version 2>&1 | head -1) in $(( $(date +%s) - t0 )) s"

t0=$(date +%s)
if ! timeout 120 executor service start >"$home/start.log" 2>&1; then fail server "$(tail1 "$home/start.log")"; fi
ok server "$(timeout 30 executor service status 2>&1 | head -1) in $(( $(date +%s) - t0 )) s"

# The app: DeepWiki's public MCP server, no account (the app-authoring skill's integrations.md example). It is a third
# party: probe it first, so a DeepWiki outage reads as that and not as Executor breaking.
dwcode=$(curl -sS -o "$home/dw.out" -w '%{http_code}' --retry 2 --max-time 30 -X POST https://mcp.deepwiki.com/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"executor-journey","version":"1"}}}' 2>"$home/dw.err")
case "$dwcode" in
  2??) grep -q '"result"' "$home/dw.out" || fail deepwiki "third party, not Executor: mcp.deepwiki.com/mcp HTTP $dwcode without an initialize result: $(tail1 "$home/dw.out")" ;;
  *) fail deepwiki "third party, not Executor: mcp.deepwiki.com/mcp HTTP ${dwcode:-none} $(tail1 "$home/dw.err") $(tail1 "$home/dw.out")" ;;
esac
ok deepwiki "mcp.deepwiki.com/mcp HTTP $dwcode"
cat > "$home/app/index.ts" <<'EOF'
import { defineApp } from "apps";
import { mcpRouter } from "apps/mcp";

export default defineApp({}, async ({ signal }) => ({
  tools: await mcpRouter({
    url: "https://mcp.deepwiki.com/mcp",
    signal,
  }),
}));
EOF
framework=$(timeout 60 executor apps framework 2>"$home/fw.err" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
[ -n "$framework" ] || fail framework "$(tail1 "$home/fw.err")"
printf '{"name":"deepwiki","private":true,"type":"module","dependencies":{"apps":"%s","@modelcontextprotocol/sdk":"1.32.1"}}\n' "$framework" > "$home/app/package.json"
ok framework "apps $framework"

t0=$(date +%s)
timeout 180 executor apps create --name DeepWiki --files "$home/app" >"$home/create.json" 2>"$home/create.err" || fail app-create "$(tail1 "$home/create.err") $(tail1 "$home/create.json")"
app=$(sed -n 's/^  "id": *"\(app_[^"]*\)".*/\1/p' "$home/create.json" | head -1)
[ -n "$app" ] || fail app-create "no app id: $(tail1 "$home/create.json")"
timeout 60 executor apps source --app "$app" >"$home/source.json" 2>"$home/source.err" || fail app-source "$(tail1 "$home/source.err")"
commit=$(tr -d '\n ' < "$home/source.json" | sed -n 's/.*"revision":{[^}]*"commit":"\([0-9a-f]*\)".*/\1/p')
[ -n "$commit" ] || fail app-source "no revision commit: $(tail1 "$home/source.json")"
timeout 300 executor apps deploy --app "$app" --commit "$commit" >"$home/deploy.json" 2>"$home/deploy.err" || fail app-deploy "$(tail1 "$home/deploy.err") $(tail1 "$home/deploy.json")"
ok app "$app deployed $commit in $(( $(date +%s) - t0 )) s"

# The job: a program that calls a real tool and returns only what it needs.
cat > "$home/job.js" <<'EOF'
const r = await tools.deepwiki.read_wiki_structure({ repoName: "UsefulSoftwareCo/executor" });
const text = JSON.stringify(r);
return { pages: (text.match(/\\n- /g) || []).length, mentionsOverview: text.includes("Overview"), chars: text.length };
EOF
t0=$(date +%s)
timeout 300 executor execute --file "$home/job.js" >"$home/result.json" 2>"$home/result.err" || fail execute "$(tail1 "$home/result.err") $(tail1 "$home/result.json")"
ok execute "in $(( $(date +%s) - t0 )) s"
echo "EXJ result $(tr -d '\n' < "$home/result.json")"
timeout 60 executor service stop >/dev/null 2>&1
ok stop "$(timeout 30 executor service status 2>&1 | head -1)"
