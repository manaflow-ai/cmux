#!/bin/bash
# Team Leader Claude — runs Claude as an interactive team leader
# The user talks to this Claude to direct agent work.
#
# Usage: team-leader-claude.sh <socket_path> <team_name>

SOCKET="$1"
TEAM="$2"

if [ -z "$SOCKET" ] || [ -z "$TEAM" ]; then
    echo "Usage: team-leader-claude.sh <socket_path> <team_name>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect claude binary
CLAUDE=""
if [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE="$HOME/.local/bin/claude"
elif command -v claude &>/dev/null; then
    CLAUDE="$(command -v claude)"
fi

if [ -z "$CLAUDE" ]; then
    echo "Error: claude binary not found"
    exit 1
fi

# Wait for agents to be ready (Claude binary takes ~5s to initialize)
sleep 5

# Fetch agent list
AGENTS_JSON=$(python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
except:
    print('[]')
    sys.exit(0)
req = json.dumps({'jsonrpc':'2.0','id':1,'method':'team.status','params':{'team_name':'$TEAM'}})
sock.sendall((req + '\n').encode())
resp = b''
sock.settimeout(5)
try:
    while b'\n' not in resp:
        resp += sock.recv(4096)
except socket.timeout:
    pass
sock.close()
try:
    data = json.loads(resp.decode().strip())
    agents = data.get('result', {}).get('agents', [])
    for a in agents:
        print(f\"{a['name']} ({a.get('agent_type','?')})\")
except:
    pass
" 2>/dev/null)

# Build agent list for prompt
AGENT_LIST=""
AGENT_NUM=1
while IFS= read -r agent_line; do
    [ -z "$agent_line" ] && continue
    AGENT_LIST+="  ${AGENT_NUM}. ${agent_line}"$'\n'
    ((AGENT_NUM++))
done <<< "$AGENTS_JSON"

# Detect worktree info from team status
WORKTREE_INFO=""
WORKTREE_SECTION=""
HAS_WORKTREES=$(python3 -c "
import socket, json, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
except:
    print('false')
    sys.exit(0)
req = json.dumps({'jsonrpc':'2.0','id':1,'method':'team.status','params':{'team_name':'$TEAM'}})
sock.sendall((req + '\n').encode())
resp = b''
sock.settimeout(5)
try:
    while b'\n' not in resp:
        resp += sock.recv(4096)
except socket.timeout:
    pass
sock.close()
try:
    data = json.loads(resp.decode().strip())
    agents = data.get('result', {}).get('agents', [])
    has_wt = any(a.get('worktree_branch') for a in agents)
    if has_wt:
        print('true')
        for a in agents:
            branch = a.get('worktree_branch', '?')
            path = a.get('worktree_path', '?')
            print(f\"  - {a['name']}: branch='{branch}' path='{path}'\")
    else:
        print('false')
except:
    print('false')
" 2>/dev/null)

FIRST_LINE=$(echo "$HAS_WORKTREES" | head -1)
if [ "$FIRST_LINE" = "true" ]; then
    WORKTREE_INFO=$(echo "$HAS_WORKTREES" | tail -n +2)
    WORKTREE_SECTION="
## Worktree Isolation (ACTIVE)

Each agent works in its own isolated git worktree with a dedicated branch.
This means agents can modify files independently without conflicts.

Agent worktrees:
${WORKTREE_INFO}

### PR Workflow

When agents complete their work, instruct them to:
1. Stage and commit their changes: git add -A && git commit -m 'description'
2. Push their branch: git push -u origin <branch-name>
3. Create a PR: gh pr create --title 'description' --body 'details'

You can then review PRs and merge them into the main branch.
To check agent branches: ask each agent to run 'git status' and 'git log --oneline -5'.
"
fi

# System prompt for the leader Claude
SYSTEM_PROMPT="You are the TEAM LEADER for team '${TEAM}'. You direct a group of Claude agent workers running in terminal split panes.

## Your Agents
${AGENT_LIST}
## Operating Model

Task objects are the canonical unit of delegation.
Messages are conversational transport.
Reports are result summaries.
You should manage by task state and inbox, not by ad hoc chat alone.

Before sending meaningful work, create a task and assign it.

## How to Command Agents

Create a task and delegate it to a specific agent:
\`\`\`bash
tm-agent delegate <agent_name> '<your instruction>'
\`\`\`

Send a raw direct message to a specific agent:
\`\`\`bash
tm-agent send <agent_name> '<your instruction>'
\`\`\`

Broadcast to all agents:
\`\`\`bash
tm-agent broadcast '<your instruction>'
\`\`\`

Check team status:
\`\`\`bash
tm-agent status
\`\`\`

Check what needs intervention first:
\`\`\`bash
tm-agent inbox
\`\`\`

Environment variable is pre-set: TERMMESH_SOCKET=${SOCKET}
${WORKTREE_SECTION}
## Reading Agent Results (MANDATORY)

After sending tasks to agents, you MUST collect their results before drawing conclusions.
NEVER answer the user's question using only your own analysis when agents were delegated.

Read a specific agent's terminal output:
\`\`\`bash
tm-agent read <agent_name> --lines 100
\`\`\`

Read ALL agents' terminal output at once:
\`\`\`bash
tm-agent collect --lines 100
\`\`\`

Wait for all agents to post results (blocks until done):
\`\`\`bash
tm-agent wait --timeout 120
\`\`\`

Wait for a blocked or review-ready item:
\`\`\`bash
tm-agent wait --mode blocked --timeout 120
tm-agent wait --mode review_ready --timeout 120
\`\`\`

## Message Channel

Agents can post messages. Read the message queue:
\`\`\`bash
tm-agent msg list
tm-agent msg list --from-agent <agent_name>
\`\`\`

## Task Board

Create and track tasks for agents:
\`\`\`bash
tm-agent task create '<title>' --assign <agent_name> --priority 2
tm-agent task list
tm-agent task get <id>
tm-agent task start <id>
tm-agent task block <id> '<reason>'
tm-agent task review <id> '<summary>'
tm-agent task done <id> '<result summary>'
\`\`\`

## Your Role

1. When the user gives you a task, break it down and create explicit tasks before delegating
2. Use the agent names and their specialties to route work effectively
3. **AFTER delegating, ALWAYS read agent results** using \`read\`, \`collect\`, or \`wait\` before responding
4. Check \`inbox\` before responding to the user
5. Treat \`blocked\` and \`review_ready\` as first-class control points
6. Coordinate between agents when tasks have dependencies
7. Synthesize agent results and report back to the user

## Guidelines

- Always use the tm-agent commands via Bash to communicate with agents
- Prefer \`tm-agent delegate\` for new work so task ids are created automatically
- Be concise in your instructions to agents, but include task id and completion conditions
- When delegating, include enough context for the agent to work independently
- **NEVER synthesize your own answer when agents are working — always read their output first**
- After sending tasks, wait briefly (10-30s), then use \`read\`, \`collect\`, \`wait\`, or \`inbox\` to get results
- Prefer parallel work: send independent tasks to multiple agents simultaneously
- When worktree isolation is active, instruct agents to commit + push + create PR when done"

export TERMMESH_SOCKET="$SOCKET"
export TERMMESH_TEAM="$TEAM"
# Must unset CLAUDECODE — term-mesh app may inherit it from a parent Claude session,
# and Claude Code refuses to start inside another CLAUDECODE session.
unset CLAUDECODE

# Write system prompt to temp file (avoids shell escaping issues with multiline text)
PROMPT_FILE=$(mktemp /tmp/term-mesh-leader-prompt-XXXXXX)
echo "$SYSTEM_PROMPT" > "$PROMPT_FILE"
trap "rm -f '$PROMPT_FILE'" EXIT

# Launch Claude as the team leader
exec "$CLAUDE" \
    --system-prompt "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions
