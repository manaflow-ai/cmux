# API versions and the compatibility promise

Pin the cmux socket or the cmux Cloud API to a date, and it keeps answering the way it did for at least 12 months after it changes.

Scripts and agents talk to cmux through two APIs: the socket of the cmux daemon (what the cmux CLI, the apps and the SDKs speak) and the cmux Cloud HTTP API at vm.cmux.dev. Code written against either should keep working when cmux updates, even code nobody looks at again. So both take a version, named by a date, and cmux keeps that version answering.

## The promise

1. No breaking change ships without a new dated version. Renaming, moving, retyping or removing a field, or changing what a value means, is breaking. Adding an optional field, a command, a route, an event or a capability is not: a client must ignore fields it does not know.
2. Every dated version keeps answering for at least 12 months after the version that replaced it. cmux translates requests and replies between the version you pinned and the current one, so you get the shape you wrote against.
3. A client that pins no version gets the current API, exactly as before. Pinning is how you opt in to the promise.

The first dated version of both APIs is 2026-11-24. A pin older than the oldest version still served is refused, with a message that names the oldest and newest dates; it is never answered in a shape you did not ask for.

## Pin the socket

Send the date you wrote your client against as api_version in set-client-info, once per connection. The daemon serves the newest version dated on or before it and answers with the version it served. From then on it translates both ways on that connection: replies and events come back in your version's shape.

```json
{"id":1,"cmd":"set-client-info","name":"my-agent","api_version":"2026-11-24"}
{"id":1,"ok":true,"data":{"api_version":"2026-11-24","api_revision":12}}
```

A pin later than the daemon knows gets its newest version, and the answer says which. identify with revisions set to true reports api_version (the newest) and min_api_version (the oldest still served).

## Pin the cmux Cloud API

Send the Cmux-Api-Version header with a date. The API serves the newest version dated on or before it, translates the request up and the JSON reply down, and names the version it served in the reply's Cmux-Api-Version header. A malformed date, or one older than the oldest version served, gets 400 UnsupportedApiVersion. No header: the current API.

```bash
curl -H "Authorization: Bearer $CMUX_API_KEY" \
     -H 'Cmux-Api-Version: 2026-11-24' \
     https://vm.cmux.dev/v1/vms
```

## What it costs

Little. An unpinned or current pin costs about 30 ns per socket reply and about 0.5 us per Cloud request. A pin one version back costs about 8 us per changed socket reply and about 9 us per Cloud reply.

## Not covered yet

Terminal byte streams, session event stream items and the version 2 resource API (cmux.protocol/2) are outside the promise for now. The cmux CLI's own commands and flags follow the CLI contract instead.

## Where it lives

| Where | What |
| --- | --- |
| [`cmux-tui/spec/api-versioning.md`](https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/cmux-tui/spec/api-versioning.md) | the promise, how a new version is added, and the benchmarks |
| [`cmux-tui/spec/api-compat.json`](https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/cmux-tui/spec/api-compat.json) | the socket's dated versions and the rules between them |
| [`workers/cmux-vm/src/api-version.ts`](https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/workers/cmux-vm/src/api-version.ts) | the Cloud API's dated versions (API_VERSIONS) |

- [CLI and MCP reference](cli.md)
- [MCP server](mcp.md)
- [Cloud machines](cloud.md)
