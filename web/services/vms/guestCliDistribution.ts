// One pinned Cloud command distribution, independent of the long-lived TUI
// daemon. The archive contains the Rust facade and official CodeRouter core.
import distribution from "./guestCliDistribution.json";

export const GUEST_CMUX_ADAPTER_PATH = "/usr/local/libexec/cmux-cloud-adapter";
const LIBEXEC = "/usr/local/libexec";
const BIN = "/usr/local/bin";

export type GuestCliDistribution = {
  url: string;
  archiveSha256: string;
  binaries: Record<string, string>;
};

/** Generate the same installer for image baking, drift repair, and local fixtures. */
export function guestCliDistributionCommand(
  verify = false,
  manifest: GuestCliDistribution = distribution,
  libexec = LIBEXEC,
  bin = BIN,
): string {
  const settings = Buffer.from(JSON.stringify({ verify, manifest, libexec, bin })).toString("base64");
  const script = `import base64, hashlib, io, json, os, pathlib, shutil, tarfile, tempfile, urllib.request
config = json.loads(base64.b64decode('${settings}'))
manifest = config['manifest']
libexec, bindir = pathlib.Path(config['libexec']), pathlib.Path(config['bin'])
release = libexec / ('cmux-cloud-' + manifest['archiveSha256'])
names = {'cmux-cloud-cli', 'coderouter'}
if set(manifest['binaries']) != names:
    raise SystemExit('invalid Cloud CLI manifest')
def valid(path, digest):
    return path.is_file() and not path.is_symlink() and os.access(path, os.X_OK) and hashlib.sha256(path.read_bytes()).hexdigest() == digest
def ready():
    return all(valid(release / name, digest) for name, digest in manifest['binaries'].items())
links = {libexec / 'cmux-coderouter': release / 'coderouter'}
links.update({bindir / name: release / 'cmux-cloud-cli' for name in ['cmux', 'coderouter', 'cr']})
if config['verify']:
    raise SystemExit(0 if ready() and all(path.is_symlink() and path.resolve() == target.resolve() for path, target in links.items()) else 1)
libexec.mkdir(parents=True, exist_ok=True)
bindir.mkdir(parents=True, exist_ok=True)
if not ready():
    with urllib.request.urlopen(manifest['url'], timeout=30) as response:
        archive = response.read(64 * 1024 * 1024 + 1)
    if len(archive) > 64 * 1024 * 1024 or hashlib.sha256(archive).hexdigest() != manifest['archiveSha256']:
        raise SystemExit('Cloud CLI download checksum mismatch')
    staging = pathlib.Path(tempfile.mkdtemp(prefix='.cmux-cli-', dir=libexec))
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as files:
            members = files.getmembers()
            if len(members) != 2 or {member.name for member in members} != names or any(not member.isfile() or member.size > 64 * 1024 * 1024 for member in members):
                raise SystemExit('invalid Cloud CLI archive')
            for member in members:
                content = files.extractfile(member).read()
                if hashlib.sha256(content).hexdigest() != manifest['binaries'][member.name]:
                    raise SystemExit('Cloud CLI executable checksum mismatch')
                target = staging / member.name
                target.write_bytes(content)
                target.chmod(0o755)
        # A concurrent install may have completed the same immutable release.
        # Replace files individually only to repair an existing damaged release.
        release.mkdir(exist_ok=True)
        for name in names:
            os.replace(staging / name, release / name)
    finally:
        shutil.rmtree(staging)
if not ready():
    raise SystemExit('Cloud CLI installation did not verify')
for path, target in links.items():
    handle, temporary = tempfile.mkstemp(prefix='.cmux-link-', dir=path.parent)
    os.close(handle)
    os.unlink(temporary)
    try:
        os.symlink(target, temporary)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary): os.unlink(temporary)
release_dirs = []
for candidate in libexec.iterdir():
    suffix = candidate.name.removeprefix('cmux-cloud-')
    if candidate == release or candidate.is_symlink() or not candidate.is_dir() or len(suffix) != 64 or any(char not in '0123456789abcdef' for char in suffix):
        continue
    release_dirs.append(candidate)
release_dirs.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
for obsolete in release_dirs[2:]:
    shutil.rmtree(obsolete, ignore_errors=True)
`;
  return `python3 -c '${script.replace(/'/g, `'\\''`)}'`;
}
