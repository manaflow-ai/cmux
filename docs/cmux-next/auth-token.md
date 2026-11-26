# A cmux access token outside the app

The cmux platform API and the hosted MCP take a cmux access token as
`Authorization: Bearer <token>`. When one is missing they answer 401
(`a cmux access token is required`). To get a token from a terminal, a script
or an agent, sign in in the cmux app, then run:

```sh
export CMUX_TOKEN=$(cmux auth token)
curl -H "Authorization: Bearer $CMUX_TOKEN" https://<platform>/v1/machines
```

`cmux auth token` asks the running cmux app for a token and prints only the
token, so command substitution works. The app keeps your sign-in to itself.
Nothing else leaves the app: no password, no Stack session, no refresh token.

## What the token is

- It is good for about ten minutes, then the API refuses it. There is no refresh
  token: run `cmux auth token` again. For a long job, get a new token before each
  call or when you see a 401.
- It acts as you, for one team (the token's `team` claim). Routes that need a
  team, such as `/v1/machines`, use that team.
- It carries this Mac's install grant: read, change your own and your team's
  Cloud resources, link machines. It never carries `execute`, so it cannot type
  into a terminal or run code on a machine.
- It is an ES256 JWT from the cmux API (`iss` `https://cmux-api/<environment>`,
  `aud` `api`). Release builds get production tokens. DEV builds get staging
  tokens, which a production platform deployment refuses.

## Options

| Option | Meaning |
| --- | --- |
| `--team TEAM` | The team, as its id (`team_` and 20 hex digits). Default: the team the app is using now (Settings > Accounts), or your personal team when none is chosen. |
| `--json` | Print one JSON object instead of the bare token (fields below). |

`--json` prints:

| Field | Value |
| --- | --- |
| `access_token` | The token |
| `token_type` | `Bearer` |
| `team` | The team id the token is for |
| `user` | Your cmux user id (the token's `sub`) |
| `expires_at` | When it expires, ISO 8601 UTC |
| `expires_in` | Seconds until then |
| `api_origin` | The cmux API that issued it |

## When it fails

`cmux auth token` prints nothing on stdout when it fails. It writes the reason
to stderr, or a JSON error with `--json`, and exits non-zero.

| Exit | Code | What to do |
| --- | --- | --- |
| 3 | `not_signed_in` | Sign in in the cmux app. |
| 3 | `no_team` | Choose a team in the cmux app, or pass `--team`. |
| 3 | `app.unreachable` | Open the cmux app. The command talks to it over its control socket. |
| 5 | `method_not_found` | Update the cmux app. |
| 1 | `feature.disabled` | Your organization turned cmux Cloud off. |
| 1 | `managed` | Your organization limits cmux on this Mac to its managed team. Ask for that team only. |
| 1 | `forbidden` | The API refused that team. Check that your account belongs to it. |
| 1 | `client_too_old` | The team needs a newer cmux. Update it. |
| 1 | `unavailable` | The cmux API didn't answer, or sent an answer cmux can't use (the message names which). Try again. |
| 1 | `local_failure` | This Mac couldn't make the token, for example the Keychain refused the install key. The message names the cause, such as `keychain(-25244: …)`. |

## Who can get one

Any process the app's control socket admits can ask for a token, the same
processes that can already drive cmux and its Cloud machines through that
socket. By default that is every process of your macOS user (socket mode
`automation`). In `cmuxOnly` mode it is only processes started inside cmux. The
token lasts minutes, but anyone who copies it can use it until it expires, so
don't paste it into logs or chats.

## Hosted tools in agent chats

Every agent chat gets cmux's hosted MCP server (`cmux-hosted`) by default. It
gives the agent the tools of your cmux account: GitHub through your cmux
connectors and the remote MCP servers you added. To turn it off, set
`agents.hostedMcp.enabled` to `false` in cmux.json, or start the daemon with
`CMUX_HOSTED_MCP=0`.

- On a Mac, the server asks the app for a token the way `cmux auth token` does
  and keeps it in memory only, never in a file, an env, argv or a log. If you
  aren't signed in, the chat lists no hosted tools. The server waits a minute
  before it asks the app again.
- On a cmux Cloud machine, no token is on the machine for this. The server
  sends each MCP message as an `mcp.call` line over the machine agent's socket.
  The agent adds the machine's own sign-in and sends the message to the
  platform's `/mcp`, so the bearer never leaves the agent. A tool call that
  takes the platform longer than 20 s fails with `integration.unreachable`.
