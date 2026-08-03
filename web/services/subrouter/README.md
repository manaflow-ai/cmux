# Hosted Subrouter

The dashboard and `/api/subrouter/accounts` use the signed-in Stack access
token to exchange a Stack team for a deterministic tenant on `sr.cmux.com`.
The Go service verifies the token and team membership. The web app stores no
tenant keys and needs no Subrouter admin token or database row.

Production defaults to `https://sr.cmux.com`; previews and local development
default to `https://staging.sr.cmux.com`. `SUBROUTER_HOSTED_URL` overrides the
environment default.

The legacy `subrouter_tenants` table remains as a read-only recovery archive.
The hosted account routes do not read or write it.
