#!/bin/bash
# A wrapper script that pipes a prompt to a command
# Usage:
#   prompt-wrapper --prompt "prompt text" -- <command> [args...]
#   prompt-wrapper --prompt-env CMUX_PROMPT -- <command> [args...]
# If no --prompt or --prompt-env is provided, falls back to $CMUX_PROMPT

PROMPT=""
PROMPT_ENV=""
COMMAND_ARGS=()
PARSING_PROMPT=false
PARSING_PROMPT_ENV=false
PARSING_COMMAND=false

# Parse arguments
for arg in "$@"; do
    if [ "$arg" = "--prompt" ]; then
        PARSING_PROMPT=true
        PARSING_COMMAND=false
        PARSING_PROMPT_ENV=false
    elif [ "$arg" = "--prompt-env" ]; then
        PARSING_PROMPT_ENV=true
        PARSING_PROMPT=false
        PARSING_COMMAND=false
    elif [ "$arg" = "--" ]; then
        PARSING_PROMPT=false
        PARSING_PROMPT_ENV=false
        PARSING_COMMAND=true
    elif [ "$PARSING_PROMPT" = true ]; then
        PROMPT="$arg"
        PARSING_PROMPT=false
    elif [ "$PARSING_PROMPT_ENV" = true ]; then
        PROMPT_ENV="$arg"
        PARSING_PROMPT_ENV=false
    elif [ "$PARSING_COMMAND" = true ]; then
        COMMAND_ARGS+=("$arg")
    fi
done

# Resolve prompt from env if requested or missing
if [ -z "$PROMPT" ]; then
    if [ -n "$PROMPT_ENV" ]; then
        # Use the specified env var
        PROMPT="$(eval echo "\${$PROMPT_ENV}")"
    elif [ -n "$CMUX_PROMPT" ]; then
        PROMPT="$CMUX_PROMPT"
    fi
fi

# If no command was provided after --, show usage
if [ ${#COMMAND_ARGS[@]} -eq 0 ]; then
    echo "Usage: $0 --prompt \"prompt text\" | --prompt-env CMUX_PROMPT -- <command> [args...]"
    exit 1
fi

# Execute the command with the prompt piped to it
echo "$PROMPT" | "${COMMAND_ARGS[@]}"

