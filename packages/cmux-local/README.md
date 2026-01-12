# CMUX Local

A CLI for orchestrating Claude Code sessions in local Docker containers.

## Quick Start

```bash
# 1. One-time setup (builds Docker image)
bun run packages/cmux-local/src/index.ts setup

# 2. Set your API key
export ANTHROPIC_API_KEY=your_key

# 3. Start a task in your project
cd ~/your-project
bun run packages/cmux-local/src/index.ts "Add dark mode toggle"

# 4. Monitor tasks and answer questions
bun run packages/cmux-local/src/index.ts
```

## Usage

### Start a Task (Quick)

```bash
# Run from your project directory
cd ~/myproject
bun run packages/cmux-local/src/index.ts "Fix the login bug"
```

This will:
1. Start a Docker container with Claude Code
2. Mount your project at `/workspace`
3. Give you a terminal URL to watch progress
4. Surface any questions Claude has

### Interactive Mode

```bash
bun run packages/cmux-local/src/index.ts
```

Commands:
- `new` - Start a new task (prompts for repo + description)
- `list` - Show all running tasks
- `open <n>` - Open task n's terminal in browser
- `q1 <answer>` - Answer question 1
- `tell <n> <message>` - Send a message to task n
- `stop <n>` - Stop task n
- `stop-all` - Stop all tasks
- `quit` - Exit

### CLI Commands

```bash
# List running tasks
bun run packages/cmux-local/src/index.ts list

# Stop all tasks
bun run packages/cmux-local/src/index.ts stop-all

# Show help
bun run packages/cmux-local/src/index.ts --help
```

## Requirements

- **Docker** - Must be running
- **ANTHROPIC_API_KEY** - Environment variable for Claude Code

## How It Works

1. **Docker containers** - Each task runs in an isolated container
2. **tmux** - Claude Code runs in a tmux session inside the container
3. **ttyd** - Web terminal for viewing/interacting with the session
4. **Docker labels** - Task metadata stored in container labels (no database needed)

## Ports

- Tasks use ports starting at 27183 (avoids common dev server ports)
- Each new task gets the next available port

## Alias (Optional)

Add to your shell config (`~/.zshrc` or `~/.bashrc`):

```bash
alias cmux-local='bun run /path/to/cmux/packages/cmux-local/src/index.ts'
```

Then use:
```bash
cmux-local "Add feature X"
cmux-local list
cmux-local
```
