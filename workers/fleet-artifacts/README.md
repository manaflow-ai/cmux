# Private fleet artifact edge

This Worker streams content-addressed fleet ZIPs from the existing private
`cmux-fleet-artifacts` R2 bucket through Cloudflare's edge. It removes the
controller from the artifact byte path. It holds only an Ed25519 public key;
the controller signs short-lived download URLs after authenticating a client.

Only `GET` and `HEAD /artifacts/<64 lowercase hex>` are accepted. A request
must have exactly `expires=<Unix seconds>` and `signature=<128 lowercase hex>`.
Expiry must be in the future and no more than 900 seconds away. Verification
covers these UTF-8 bytes, without a trailing newline:

```text
fleet-artifact-v1
<URL host, including port if present>
<URL pathname>
<expires>
```

The controller derives its Ed25519 seed as
`SHA256("cmux-fleet-artifacts-v1\n" + R2 secret access key)`. Only its 32-byte
public key, lowercase hex, is provided as `ARTIFACT_PUBLIC_KEY`. The private
seed and R2 credential never enter this Worker or deployment workflow.

Every request verifies its signature before touching R2. There is no list
route, public object route, or cache path that bypasses authentication. The
Worker streams the R2 body without cloning, buffering, or filling the Cache
API. Responses are `private, no-store`; request logging is disabled because
download URLs carry replayable signatures. Clients still verify the digest
and fall back to the authenticated controller stream on transport failure.

Run `npm test` here for the edge and read-only deployment checks. The
`Fleet artifact CDN` workflow also runs these tests on matching PRs. Deployment
is a manual dispatch from `main` in `manaflow-ai/cmux`, using the existing
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repository secrets. Supply
the controller's public key as the nonsecret `public_key` input. The workflow
refuses unless the fixed bucket exists with `r2.dev` disabled and no public
custom domains. It changes only the fixed Worker and verifies that unsigned
artifact requests receive its 403 response. It never creates a bucket or
changes public access or retention. Existing R2 retention remains authoritative.

Configure the controller's artifact credential file with the resulting HTTPS
edge origin only after a signed download verifies the expected digest. Leaving
the controller's CDN setting unset keeps its direct R2 and controller-stream
fallback paths available. Public-key rotation requires deploying the new public
key before enabling the matching controller signing key.
