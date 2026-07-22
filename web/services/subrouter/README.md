# Subrouter tenant service

Server-side integration between the cmux web app and the subrouter multi-tenant
account API. Powers `/dashboard/ai-accounts` and the `/api/subrouter/accounts`
routes.

## Configuration

The dashboard and API routes stay disabled (HTTP 503, "AI account management
isn't available yet") until both secrets are set:

- `SUBROUTER_ADMIN_TOKEN` — admin bearer token for tenant provisioning.
- `SUBROUTER_TENANT_KEY_SECRET` — base64-encoded 32-byte key used to encrypt
  tenant keys (AES-256-GCM) before they are stored in `subrouter_tenants`.
  Generate with `openssl rand -base64 32`. Rotating this secret invalidates
  previously stored tenant keys.
- `SUBROUTER_BASE_URL` — optional; defaults to `https://subrouter.cmux.dev` in
  production and `https://subrouter-staging.cmux.dev` elsewhere.
