// Signs SLSA build provenance for files into a local Sigstore bundle, with no GitHub REST call.
//
//   node scripts/ci/attest-offline/sign.mjs OUT_BUNDLE FILE...
//
// The same library and predicate actions/attest-build-provenance uses (@actions/attest's
// attestProvenance), with skipWrite: the job's OIDC token, Fulcio and Rekor sign it, and the
// bundle lands in OUT_BUNDLE instead of the attestations API. That API write is the only call
// the action makes on the installation's shared REST budget, and waiting for that budget held
// nightly.yml's attest-nightly-remote-daemon for 17.6 minutes (run 45562645699). Verify with
// `gh attestation verify FILE --bundle OUT_BUNDLE --repo OWNER/REPO`. Subject names are the
// files' base names, as the action names them. SIGSTORE picks the instance (public-good for a
// public repository, as the action picks; github otherwise).
import { attestProvenance } from '@actions/attest'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const [out, ...files] = process.argv.slice(2)
if (!out || files.length === 0) {
  console.error('usage: sign.mjs OUT_BUNDLE FILE...')
  process.exit(2)
}
if (!process.env.ACTIONS_ID_TOKEN_REQUEST_URL) {
  console.error('sign.mjs: no OIDC token here; the job needs permissions: id-token: write')
  process.exit(1)
}

const subjects = []
for (const file of files) {
  const sha256 = createHash('sha256').update(await readFile(file)).digest('hex')
  subjects.push({ name: path.basename(file), digest: { sha256 } })
}
const sigstore = process.env.SIGSTORE === 'github' ? 'github' : 'public-good'
const attestation = await attestProvenance({ subjects, sigstore, token: '', skipWrite: true })
await writeFile(out, JSON.stringify(attestation.bundle) + '\n')
for (const s of subjects) console.log(`signed ${s.name} sha256:${s.digest.sha256}`)
if (attestation.tlogID) console.log(`Rekor log index ${attestation.tlogID}`)
console.log(`bundle: ${out}`)
