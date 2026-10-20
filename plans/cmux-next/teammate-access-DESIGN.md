# Teammate access: secure-by-default remote access to a teammate's machine

Status: slice 1 built (CLI + listener admission, default off).
Builds on: [remote-hosts.md](remote-hosts.md) (`cmux host enable|serve|allow|dial`).

## 1. Goal

Lawrence (`lawrence@manaflow.ai`) can reach a teammate's machine (Leo, Aziz) to see what their
cmux is doing and, if they choose, to run agent sessions there, without Tailscale SSH, without
an SSH key on their machine, and without any new inbound port on Lawrence's own Mac.

Hard rules (from the request):

1. The teammate sees and approves access once, on their own machine. Nothing is installed or
   turned on silently. An auto-update never grants access.
2. A visible indicator while connected; one command (and, slice 2, one click) revokes.
3. Listen only on the tailnet interface. Never `0.0.0.0`, never a public address.
4. Authenticate by Tailscale identity (WhoIs), and only logins on the teammate-access
   allowlist (default: `lawrence@manaflow.ai` only).
5. Scoped: default read-only status. Agent sessions and the raw shell are separate grants;
   the raw shell only when the teammate turns it on.
6. Audit log on the teammate's machine.
7. Lawrence's Mac opens no inbound port: it only dials out.

## 2. Why not plain SSH or Tailscale SSH

| | Plain SSH (Remote Login) | Tailscale SSH | cmux teammate access |
|---|---|---|---|
| Listens on | every interface, port 22 | tailnet (tailscaled) | tailnet addresses only (existing `cmux host serve`) |
| Who decides | whoever holds a key in `authorized_keys` | tailnet admin ACL (`ssh` rules), not the teammate | the teammate, per login, on their machine |
| Scope | full shell as the user | full shell as the mapped user | status / agents / shell, each granted separately |
| Turn on | System Settings > Remote Login (admin) + key exchange | admin ACL change + `tailscale up --ssh` on the teammate's node | teammate runs `cmux host grant` (types `yes`) |
| Revoke | edit `authorized_keys` | admin ACL change | `cmux host revoke LOGIN` closes open connections |
| Audit on the teammate's machine | sshd log, no scope | tailscaled log | `~/.cmux/host/audit.jsonl`, one line per decision |
| Silent install risk | a script can append a key | admin can enable it tailnet-wide | an update ships code only; a grant needs a person at a TTY |

Plain SSH and Tailscale SSH both give a full shell as soon as they work, and the person whose
machine it is is not the one who decides. That fails rules 1, 5 and (for plain SSH) 3.

## 3. Threat model

Assets: the teammate's files, credentials, terminals and agent sessions; Lawrence's Mac.

| Threat | Defense |
|---|---|
| Someone on the internet or LAN connects | Listener binds each tailnet address only (`serve.rs`); a non-tailnet peer address is refused before WhoIs (`admit::decide`). |
| Another tailnet user connects | WhoIs login must match a grant **and** be on the teammate allowlist. Tagged nodes (no person) and nodes shared in from another tailnet are refused. |
| A process on the teammate's machine dials its own tailnet address to borrow the node identity | Refused: peer is one of the host's own addresses or loopback (existing rule). |
| An auto-update (Sparkle nightly, hq `cmux-ci` self-update) turns access on | Updates ship binaries only. Teammate access is off unless `remote.json` has a consented grant, and `cmux host grant` refuses without an interactive terminal and a typed `yes`. No update path runs `grant`. |
| Grant written for an arbitrary login | Grant time and admission time both check the allowlist; a grant for a login off the list is never honored. |
| A grant that was requested but not approved | Admitted only when `consented_at` is set; otherwise refused `awaiting_consent` and logged. |
| Lawrence's account is compromised | Scope limits damage: default grant is `status` only; `shell` is never on by default. Teammate revokes with one command. Audit log shows every connection. |
| Lawrence's Mac exposed | It only dials out (`cmux host dial` / `list`); no listener, no new port. |
| Local malware running as the teammate | Out of scope: it can already do anything the user can (including edit `remote.json`). Consent protects against remote and automated delivery, not against code already running as the user. |
| Trickle / flood of connections | Existing bounds: 5 s preface, 4 KiB line, 32 pending (4 per peer). |

## 4. Model

`~/.cmux/host/remote.json` (0600) gains:

```json
{
  "teammate_access": false,
  "grants": [
    {
      "login": "lawrence@manaflow.ai",
      "scopes": ["status"],
      "consented_at": "2026-10-20T09:00:00Z",
      "consented_via": "cli-tty",
      "revoked_at": null
    }
  ]
}
```

- `teammate_access` is the default-off setting. Grants are ignored while it is off.
- Scopes:
  - `status`: the read-only probe (host name, OS, version, session, access, scopes).
  - `agents`: run and watch cmux agent sessions. Reserved in slice 1: the listener refuses it
    (`scope_not_granted`) until slice 2 adds a filtered daemon proxy that passes only the agent
    RPCs.
  - `shell`: full daemon connection (terminals, input) as the teammate. Only when the teammate
    asks for it by name (`--scope shell`), with a second warning.
- Allowlist: `TEAMMATE_ALLOWLIST = ["lawrence@manaflow.ai"]`, compiled in. Changing it is a
  code change, reviewed like any other.
- Admission order (per connection, config reread each time): disabled → own address/loopback →
  non-tailnet → WhoIs failed → shared → tagged → owner → `allow` list (existing, full access)
  → teammate grant (needs `teammate_access`, allowlist, consent, not revoked) → refused.
- The existing `cmux host allow` (full access, by name) is unchanged; teammate grants are the
  scoped, consented path and are what we ask Leo and Aziz to use.

## 5. Consent flow

Slice 1 (CLI, this change):

```
leo$ cmux host enable                 # existing: listener on Leo's tailnet addresses, owner = Leo
leo$ cmux host grant lawrence@manaflow.ai
  lawrence@manaflow.ai will be able to, from their tailnet devices:
    - see this machine's cmux status (read-only)
  Every connection is written to ~/.cmux/host/audit.jsonl.
  Revoke at any time: cmux host revoke lawrence@manaflow.ai
  Type yes to allow:
```

- Refuses without a TTY on stdin and stderr (so no script, installer or update can grant).
- Refuses logins not on the allowlist.
- `--scope status|agents|shell` (repeatable). `shell` prints an extra warning.
- `cmux host grants` lists grants; `cmux host status` lists grants and live teammate
  connections (the CLI indicator).
- `cmux host revoke LOGIN` sets `revoked_at` and restarts the listener, which closes open
  connections at once.

Slice 2 (Mac app, not in this change):

- Settings > Remote > "Teammate access": off by default. The consent sheet is the same text as
  above, with Allow / Don't Allow; it writes the grant with `consented_via: "app"`.
- Menu-bar and sidebar indicator while a teammate connection is open ("Lawrence is connected:
  status"), with a Revoke button (one click).
- Notification on each new teammate connection.

## 6. Audit log

`~/.cmux/host/audit.jsonl`, 0600, one JSON line per admission decision:
`{"ts", "peer", "login", "node", "decision": "owner|allowed|guest|refused", "reason", "scopes", "op"}`.
Never sent anywhere. Lines are appended; the file is rotated at 5 MiB (`audit.jsonl.1`).

## 7. What reaches Leo and Aziz, and when

- Delivery channel: the cmux-next nightly (Sparkle) they already run, once this lands on
  `feat-cmux-next` and a nightly is built. The hq `cmux-ci` self-update is not used: it is a
  build client, it has no UI for consent, and it must not start listeners.
- What the update changes on their machine: nothing until they act. No listener starts, no
  grant exists, `teammate_access` is false.
- What we ask them to do (a message from Lawrence, not automation): run the two commands in
  section 5 (or, after slice 2, flip the Settings toggle and click Allow).
- Then Lawrence runs `cmux host list` / `cmux host dial <leo-host>` from his Mac (outbound).

## 8. Slices

1. (this change) Grant model, consent-gated CLI, scoped admission (`status`, `shell`;
   `agents` refused), audit log, revoke. Tests: refuses non-tailnet, non-allowlisted identity,
   before consent, revoked, while setting off; scope gating; audit file mode.
2. Mac app consent sheet, indicator, one-click revoke, notification.
3. `agents` scope: filtered daemon proxy (allowlist of agent RPCs, no terminal input to
   non-agent surfaces).
4. Optional expiry (`--for 8h`) and per-session approval ("ask me each time").
