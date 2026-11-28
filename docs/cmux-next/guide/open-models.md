# Open-weight models

Run coding agents in cmux on open-weight models: on this Mac, on your own GPU machine, or on a server your team runs.

Point an agent at any server that speaks the Chat Completions API (OpenAI-compatible), on this Mac, on your own GPU machine, or on your team's inference server, and it runs in cmux like Claude Code or Codex.

## Which agents in cmux can run open-weight models?

Any agent whose models come from providers you set up. cmux knows OpenCode and Pi out of the box: install one and it shows in the model picker, using the providers you set up for it in your terminal. Add any other agent that speaks ACP in Settings > Agents, or with:

```bash
cmux agent add-harness
```

The simplest path is your own endpoint, below: one command makes the agent, and cmux keeps its key in the Keychain.

## How do I run an agent on a model server on my Mac?

Start the model server, then add it as an agent. Local servers usually listen on localhost and serve the Chat Completions API under /v1.

```bash
cmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL
cmux harness secret set local CMUX_BYO_API_KEY
cmux harness doctor local
```

- MODEL is the id the server lists for the model.
- A server that takes no key still needs a value stored. Any text works.
- This agent runs through OpenCode, so install OpenCode first.
- doctor sends one real prompt. A first prompt can wait while the server loads the model. doctor waits up to 120 seconds per step; --timeout gives it longer.

## How do I use a model server on my own GPU machine?

Two ways. Neither puts the server on the public internet.

Agent on your Mac, model on the GPU machine: forward the server's port over SSH, then add the forwarded address as above. A server with its own https address works directly with that address.

```bash
ssh -N -L 8080:127.0.0.1:8080 gpu-box
```

Agent and model both on the GPU machine: add the machine to cmux (Add Machine… in the command palette, or the command below). Then, on that machine, add the endpoint at its own localhost.

```bash
cmux acp machine enroll gpu-box

# then, on gpu-box:
acpmux harness add local --example openai-endpoint --base-url http://127.0.0.1:8080/v1 --model MODEL
acpmux harness secret set local CMUX_BYO_API_KEY
acpmux harness doctor local
```

On Linux, harness secret set stores the key with secret-tool, so the machine needs a running secret service. Then start a chat on that machine (cmux remote new-workspace) and pick local in the model picker.

## How do I use my team's inference server?

Add it with its https address and the key your team gives you. cmux refuses plain http to anything but localhost, so a server without https needs a forwarded port, as above.

```bash
cmux harness add team --example openai-endpoint --base-url https://llm.example.com/v1 --model MODEL
cmux harness secret set team CMUX_BYO_API_KEY
cmux harness doctor team
```

## Can a Cloud machine run an open-weight model?

Not yet: Cloud machines have no GPU today. Run the model on your own machine or on a server your team runs. cmux inference also serves open-weight models, paid with cmux credits.

- [Run agents on your own API keys](own-keys.md)
- [Remote machines and Tailscale](remote.md)
- [Plans and credits](plans.md)
