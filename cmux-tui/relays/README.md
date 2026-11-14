# cmux relay deployments

`crates/cmux-relay` is the provider-neutral encrypted circuit relay. The
deployment directories package that binary for a specific hosting platform.

| Directory | Status | State model |
| --- | --- | --- |
| `azure/` | cmux Cloud service foundation | In-memory shard, one active VM per shard |
| `cloudflare-do/` | Compatibility experiment | Durable Objects |

cmux Cloud uses `azure/`. The Cloudflare Durable Object deployment is not part
of the cmux Cloud path and must not be used for new machines.
