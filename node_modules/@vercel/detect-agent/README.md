# @vercel/detect-agent

A lightweight utility for detecting if code is being executed by an AI agent or automated development environment.

## Installation

```bash
npm install @vercel/detect-agent
```

## Usage

```typescript
import { determineAgent } from '@vercel/detect-agent';

const { isAgent, agent } = await determineAgent();

if (isAgent) {
  console.log(`Running in ${agent.name} environment`);
  // Adapt behavior for AI agent context
}
```

## Supported Agents

This package can detect the following AI agents and development environments:

- **Custom agents** via `AI_AGENT` environment variable
- **Cursor** (cursor editor and cursor-cli)
- **Claude Code** (Anthropic's Claude)
- **Devin** (Cognition Labs)
- **Gemini CLI** (Google)
- **Codex** (OpenAI)
- **Replit** (online IDE)

## The AI_AGENT Standard

We're promoting `AI_AGENT` as a universal environment variable standard for AI development tools. This allows any tool or library to easily detect when it's running in an AI-driven environment.

### For AI Tool Developers

Set the `AI_AGENT` environment variable to identify your tool:

```bash
export AI_AGENT="your-tool-name"
# or
AI_AGENT="your-tool-name" your-command
```

### Recommended Naming Convention

- Use lowercase with hyphens for multi-word names
- Include version information if needed, separated by an `@` symbol
- Examples: `claude-code`, `cursor-cli`, `devin@1`, `custom-agent@2.0`

## Use Cases

### Adaptive Behavior

```typescript
import { determineAgent } from '@vercel/detect-agent';

async function setupEnvironment() {
  const { isAgent, agent } = await determineAgent();

  if (isAgent) {
    // Running in AI environment - adjust behavior
    process.env.LOG_LEVEL = 'verbose';
    console.log(`🤖 Detected AI agent: ${agent.name}`);
  }
}
```

### Telemetry and Analytics

```typescript
import { determineAgent } from '@vercel/detect-agent';

async function trackUsage(event: string) {
  const result = await determineAgent();

  analytics.track(event, {
    agent: result.isAgent ? result.agent.name : 'human',
    timestamp: Date.now(),
  });
}
```

### Feature Toggles

```typescript
import { determineAgent } from '@vercel/detect-agent';

async function shouldEnableFeature(feature: string) {
  const result = await determineAgent();

  // Enable experimental features for AI agents
  if (result.isAgent && feature === 'experimental-ai-mode') {
    return true;
  }

  return false;
}
```

## Contributing

We welcome contributions! Please see our [contributing guidelines](../../CONTRIBUTING.md).

### Adding New Agent Support

To add support for a new AI agent:

1. Add detection logic to `src/index.ts`
2. Add comprehensive test cases in `test/unit/determine-agent.test.ts`
3. Update this README with the new agent information
4. Follow the existing priority order pattern

## Links

- [GitHub Repository](https://github.com/vercel/vercel/tree/main/packages/detect-agent)
- [npm Package](https://www.npmjs.com/package/@vercel/detect-agent)
- [Vercel Documentation](https://vercel.com/docs)
