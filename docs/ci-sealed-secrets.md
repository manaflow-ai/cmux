# Sealed secrets: a credential minted in CI, stored in another repository's environment

Some credentials are made by a CI job: a password it just set, a token it just issued. The job's
`GITHUB_TOKEN` cannot write secrets in another repository, and no GitHub App should hold
`secrets: write` just to carry one value across. So the job seals each value to the target
environment's public key and publishes only ciphertext. Only GitHub can open it. A maintainer with
ordinary write access to the target repository then stores it. The plaintext never leaves the job
that made it.

- `scripts/ci/sealed_secrets.py`: `seal_bundle(repo, environment, key_id, key, {NAME: value})`
  seals with libsodium's `crypto_box_seal` (the encryption GitHub's secrets API takes) and returns a
  bundle (JSON: target repo, environment, `key_id`, `key`, ciphertexts). `put BUNDLE` stores it.
- A bundle whose environment is `None` goes to the repository's own Actions secrets, for a job with no
  `environment:` (cmux-platform's `ci.yml`: targets `platform-staging` and `platform-production`). Pin
  `gh api repos/OWNER/REPO/actions/secrets/public-key` for it; `put` needs write access to that repository's secrets.
- Pin the target environment's `key_id` and `key` in the producing script. To read them, run
  `gh api repos/OWNER/REPO/environments/ENV/secrets/public-key`.
- `put` reads the live public key first. If its `key_id` or bytes differ from the bundle's, it writes
  nothing and says so: update the pin and run the producer again.
- Mask the value with `::add-mask::` as soon as it exists, and never put it in an environment
  variable, an argument, a file or a log. When the producer rotates the credential, a rerun replaces
  it, so no copy needs to be kept anywhere else.

## Cloud capture account

`.github/workflows/cloud-capture-provision.yml` takes no inputs and runs only from `feat-cmux-next`,
in the `cloud-vm-staging` environment. It finds or creates the staging test account
(`cloud_capture_provision.py`), sets a new random password and the `pro` operator plan, checks that
the account signs in, and uploads the `sealed-secrets` artifact. That artifact holds
`CLOUD_CAPTURE_STACK_EMAIL` and `CLOUD_CAPTURE_STACK_PASSWORD`, sealed to the team's `cloud-capture`
capture environment. To run it and store the result:

```sh
gh workflow run cloud-capture-provision.yml -R manaflow-ai/cmux --ref feat-cmux-next
gh run download RUN_ID -R manaflow-ai/cmux -n sealed-secrets -D "$(mktemp -d)"
python3 scripts/ci/sealed_secrets.py put DIR/sealed-secrets.json
```

Rerun it to rotate the password. The capture job reads only the two secrets. It never sees the
staging server key and never creates users.

## Staging INTERNAL_TOKEN

`.github/workflows/internal-token-staging.yml` runs only from `feat-cmux-next`, in `cmux-next-staging`. It mints a
fresh `INTERNAL_TOKEN`, seals it to this repository's `cloud-vm-staging` environment as
`PLATFORM_STAGING_INTERNAL_TOKEN` (the classic migration staging proof's bearer, cmuxterm-hq#8793), then puts it on
`cmux-platform-staging` and, when that Worker already has one, `cmux-api-staging`. Every run is a rotation of all
three. To run it and store the result:

```sh
gh workflow run internal-token-staging.yml -R manaflow-ai/cmux --ref feat-cmux-next
gh run download RUN_ID -R manaflow-ai/cmux -n sealed-secrets -D "$(mktemp -d)"
python3 scripts/ci/sealed_secrets.py put DIR/sealed-secrets.json
```
