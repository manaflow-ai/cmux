# cmux-local worker image
# Minimal image with Claude Code + tmux + ttyd for web terminal + MCP orchestrator

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install essentials
RUN apt-get update && apt-get install -y \
    curl \
    git \
    tmux \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install ttyd for web terminal (detect architecture)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.aarch64 -o /usr/local/bin/ttyd; \
    else \
        curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 -o /usr/local/bin/ttyd; \
    fi && \
    chmod +x /usr/local/bin/ttyd

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Install MCP SDK globally for the orchestrator server
RUN npm install -g @modelcontextprotocol/sdk

# Create directories
RUN mkdir -p /opt/cmux /tmp/cmux /root/.claude

# Copy MCP server
COPY src/mcp-server.ts /opt/cmux/mcp-server.ts

# Create Claude Code settings with MCP server configuration
RUN echo '{\
  "mcpServers": {\
    "cmux-orchestrator": {\
      "command": "npx",\
      "args": ["tsx", "/opt/cmux/mcp-server.ts"]\
    }\
  }\
}' > /root/.claude/settings.json

# Create CLAUDE.md template that instructs Claude to use the MCP tools
COPY claude-instructions.md /opt/cmux/CLAUDE.md

# Create workspace
WORKDIR /workspace

# Expose ttyd port
EXPOSE 7681

# Default: start web terminal with bash
CMD ["ttyd", "-p", "7681", "bash"]
