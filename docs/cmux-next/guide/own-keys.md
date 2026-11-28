# Run agents on your own API keys

Use your own API key, your cloud provider, or your own model endpoint for Claude Code, Codex, and other agents in cmux.

Yes: cmux runs Claude Code, Codex, and other agents on your own API keys, and the key's own account is billed. cmux does not meter these agents or see their bill.

## How do I use my own API key with Claude Code in cmux?

cmux reads your key the way Claude Code does, so a key that works in your terminal works in cmux. Pick one of three ways.

- From your shell. Export ANTHROPIC_API_KEY in ~/.zprofile or ~/.zshrc. The agent daemon reads your login shell, so every Claude Code chat gets the ANTHROPIC_* and CLAUDE_* variables your terminal has. A change to those files applies to the next chat you start. An apiKeyHelper in Claude Code's settings.json works too.
- From a chat. When Claude Code is not signed in, the chat's sign-in card has Use an API key. cmux saves the key where Claude Code reads it (env.ANTHROPIC_API_KEY in Claude Code's settings.json) and starts the chat again on it.
- For one chat. In the model picker, choose Add account…, then Use an API key. Give where the key is, not the key: keychain:NAME, env:VARIABLE, or file:/absolute/path. Then pick that account in any chat. Other chats keep their own account.

```bash
# ~/.zprofile
export ANTHROPIC_API_KEY=your-key
```

## How do I use Claude through my cloud provider?

Turn on Claude Code's own provider switch in your login shell. cmux passes it to every Claude Code chat. It passes the provider's credential and region variables too, but only when your own switch is on.

```bash
# ~/.zprofile: one of these, with the provider's usual variables
export CLAUDE_CODE_USE_BEDROCK=1   # AWS_REGION, AWS_PROFILE, ...
export CLAUDE_CODE_USE_VERTEX=1    # CLOUD_ML_REGION, ANTHROPIC_VERTEX_PROJECT_ID, ...
export CLAUDE_CODE_USE_FOUNDRY=1
```

Claude Code's own setup for each provider works as it does in a terminal. cmux only passes the variables through.

## How do I use Codex with an API key?

Codex keeps its API key in its own login. When Codex is not signed in, the chat's sign-in card has Use an API key: cmux runs codex login --with-api-key and gives it the key on stdin, so the key is never on a command line. In a terminal, the same step is:

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

OPENAI_* and CODEX_* variables in your login shell reach Codex chats too.

## How do I connect my own model endpoint?

An endpoint that speaks Claude's Messages API, or the Chat Completions API (OpenAI-compatible), becomes an agent with one command. It can be a company gateway, a team inference server, or a model server on this Mac.

```bash
# Messages API, run through Claude Code
cmux harness add gateway --example anthropic-endpoint --base-url https://llm.example.com --model MODEL
cmux harness secret set gateway ANTHROPIC_AUTH_TOKEN
cmux harness doctor gateway

# Chat Completions API (compatible endpoint), run through OpenCode
cmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL
cmux harness secret set local CMUX_BYO_API_KEY
cmux harness doctor local
```

- secret set asks for the key without showing it, or reads it from stdin. It keeps the key in the Keychain on macOS (secret-tool on Linux). The agent's profile file holds only the item's name.
- The base URL must use https. Plain http works only to localhost, 127.0.0.1, or ::1.
- doctor sends one real prompt. When it fails, it says what to fix: the key, the base URL, or the model id.
- The new agent shows in the model picker. Your own Claude sign-in and ANTHROPIC_* variables never redirect it.
- A compatible endpoint runs through OpenCode, so install OpenCode first.

## How do I give an agent on a Cloud machine my key?

- Claude Code and Codex: when a Cloud chat is not signed in, its sign-in card offers to sign in to Claude or Codex, or Use an API key. Either one signs in that machine only. Your Mac's login stays on your Mac.
- Other keys a repository's machine needs: list their names under [secrets] in the repository's .cmux/machine.toml, then store each value on your Mac with cmux cloud secret set. The value stays in your Mac's Keychain and goes to the machine only over its own connection. Names that would send agents elsewhere (ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, OPENAI_API_KEY, OPENAI_BASE_URL, and others) are refused there.

```bash
cmux cloud secret set MY_SERVICE_KEY
```

On machines you add yourself, your vault can keep a key out of the agent's reach. Agents get a placeholder (cmux-secret://NAME), and the machine adds the real value only to requests to the hosts you list:

```bash
cmux machine vault set MY_SERVICE_KEY --host api.example.com
cmux machine vault grant MACHINE
```

## Does cmux keep prompt caching on with my own key?

Yes. cmux never turns prompt caching off, and it starts every Claude Code chat on the one-hour cache. By itself, Claude Code uses the five-minute cache with an API key, your own endpoint, or a cloud provider: after a pause of more than five minutes, the whole prompt is written again. With the one-hour cache, a chat you come back to within the hour reads its prompt from the cache.

Writes to the one-hour cache cost a little more than writes to the five-minute one. To use five minutes:

```bash
cmux settings set agents.promptCache 5m
```

The setting applies to chats you start after the change. A cache variable you set yourself (CLAUDE_CODE_PROMPT_CACHE_TTL, FORCE_PROMPT_CACHING_5M, DISABLE_PROMPT_CACHING) wins over it.

- [Audit agent spend](agent-spend.md)
- [Open-weight models](open-models.md)
- [Plans and credits](plans.md)
- [Cloud machines](cloud.md)
