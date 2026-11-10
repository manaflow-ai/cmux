//! The shell and Python the warm's login copy runs on the machine: byte for byte the Swift start's
//! (`CloudCredentialInstaller`, `CloudMachineLogin`), which the start path still runs until it moves
//! here too. `tests/test_cloud_login_copy_scripts.py` fails when the two differ.

/// The owner guest check (`CloudCredentialInstaller.preflight`): an owner guest with the image's launchers, and the
/// staging folder made as `cmux`'s own 0700 folder.
pub(super) const PREFLIGHT: &str = r##"set -eu
[ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = owner ]
[ -f /etc/cmux/agent-auth.sh ]
if [ "$(id -u)" = 0 ]; then install -d -m 700 -o cmux -g cmux /home/cmux/.cmux/credential-transfer; else
  [ "$(id -un)" = cmux ]; (umask 077 && mkdir -p /home/cmux/.cmux/credential-transfer); chmod 700 /home/cmux/.cmux/credential-transfer
fi
[ ! -L /home/cmux/.cmux/credential-transfer ] && [ "$(stat -c %U /home/cmux/.cmux/credential-transfer)" = cmux ]"##;

/// The installer (`CloudCredentialInstaller.script`), run by [`install_command`].
pub(super) const INSTALL_SCRIPT: &str = r##"import json, os, pathlib, pwd, stat, sys, tempfile
provider, source = sys.argv[1:3]
kinds = set((sys.argv[3] if len(sys.argv) > 3 else 'owner').split(',')) & {'owner', 'team'}
policy = pathlib.Path('/etc/cmux')
if (policy / 'vm-kind').read_text().strip() not in kinds or not (policy / 'agent-auth.sh').is_file():
    sys.exit(70)
user = pwd.getpwnam('cmux')
home = pathlib.Path(user.pw_dir)
source = pathlib.Path(source)
if source.is_symlink() or not source.is_file(): sys.exit(71)
if os.geteuid() == 0:
    os.chown(source, user.pw_uid, user.pw_gid)
    os.setgroups([]); os.setgid(user.pw_gid); os.setuid(user.pw_uid)
if os.geteuid() != user.pw_uid: sys.exit(71)
os.umask(0o077)
def private_dir(path):
    if path.is_symlink(): raise ValueError()
    path.mkdir(parents=True, exist_ok=True)
    if path.stat().st_uid != os.geteuid(): raise ValueError()
    path.chmod(0o700)
def save(path, value):
    private_dir(path.parent)
    if path.is_symlink(): raise ValueError()
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as f: f.write(value)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
try:
    # Custom endpoints/keys must never receive the transferred subscription credential.
    conflicts = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                 'CLAUDE_CONFIG_DIR', 'OPENAI_BASE_URL', 'CODEX_HOME', 'CODEX_API_KEY']
    if any(os.environ.get(k) for k in conflicts): raise ValueError()
    if os.environ.get('CMUX_' + provider.upper() + '_AUTH') == 'team': raise ValueError()
    value = source.read_text()
    if provider == 'claude':
        settings = home / '.claude/settings.json'
        if settings.is_symlink(): raise ValueError()
        config = json.loads(settings.read_text()) if settings.exists() else {}
        env = config.setdefault('env', {})
        if 'apiKeyHelper' in config or any(env.get(k) for k in conflicts): raise ValueError()
        env['CLAUDE_CODE_OAUTH_TOKEN'] = value
        save(settings, json.dumps(config))
        # The image launcher checks this standard Claude login marker before starting
        # Claude; keep the token in the same private 0600 file so the next launch selects own.
        save(home / '.claude/.credentials.json', json.dumps({'claudeAiOauth': {'accessToken': value}}))
    elif provider == 'codex':
        config = home / '.codex/config.toml'
        if config.is_symlink(): raise ValueError()
        if config.exists():
            import tomllib
            settings = tomllib.loads(config.read_text())
            if settings.get('model_provider', 'openai') not in ('openai', 'cmux'): raise ValueError()
            if settings.get('cli_auth_credentials_store', 'file') not in ('file', 'auto'): raise ValueError()
        save(home / '.codex/auth.json', json.dumps(json.loads(value)))
    else: raise ValueError()
    save(home / '.config/cmux/agent-auth' / provider, 'own\n')
except Exception:
    sys.exit(72)
finally:
    source.unlink(missing_ok=True)"##;

/// Sets HOME to the work user's (`cmux`) home before the machine login probe (`CloudMachineLogin.workHome`).
pub(super) const WORK_HOME: &str = r##"cmux_probe_home=$(python3 -I -c "import pwd; print(pwd.getpwnam('cmux').pw_dir)" 2>/dev/null) && [ -n "$cmux_probe_home" ] && HOME=$cmux_probe_home && export HOME"##;

/// The machine login probe's Python (`CloudMachineLogin.script`), run by [`login_probe`].
pub(super) const PROBE_SCRIPT: &str = r##"import hashlib, json, os, pathlib, pwd, sys, urllib.error, urllib.request
expected, url = sys.argv[1:3]
def answer(word):
    print(word)
    sys.exit(0)
try: home = pathlib.Path(pwd.getpwnam('cmux').pw_dir)
except KeyError: home = pathlib.Path(os.environ.get('HOME') or '/root')
def read(path):
    try: value = json.loads(path.read_text())
    except Exception: return {}
    return value if isinstance(value, dict) else {}
def text(value): return value if isinstance(value, str) else ''
env = read(home / '.claude/settings.json').get('env')
token = text(os.environ.get('CLAUDE_CODE_OAUTH_TOKEN')) or text(env.get('CLAUDE_CODE_OAUTH_TOKEN') if isinstance(env, dict) else None)
if not token:
    oauth = read(home / '.claude/.credentials.json').get('claudeAiOauth')
    if not isinstance(oauth, dict): answer('working')
    if oauth.get('refreshToken'): answer('session')
    token = text(oauth.get('accessToken'))
if not token: answer('working')
if expected and hashlib.sha256(token.encode()).hexdigest() == expected: answer('cached')
request = urllib.request.Request(url, headers={'authorization': 'Bearer ' + token, 'anthropic-version': '2023-06-01',
                                               'anthropic-beta': 'oauth-2025-04-20'})
try:
    urllib.request.urlopen(request, timeout=8).close()
except urllib.error.HTTPError as error:
    body = ''
    try: body = error.read(4096).decode('utf-8', 'replace')
    except Exception: pass
    # A 401 the provider gives a header it no longer takes is not this token's rejection.
    answer('rejected' if error.code == 401 and 'not supported' not in body else 'working')
except Exception:
    answer('working')
answer('working')"##;

/// The provider endpoint the probe asks: an authenticated read that costs no tokens.
pub(super) const PROBE_ENDPOINT: &str = "https://api.anthropic.com/v1/models?limit=1";

/// `'value'` for a POSIX shell (`CloudCredentialInstaller.quote`).
pub(super) fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Prints one word of the machine's Claude login (`CloudMachineLogin.probe`): `none`, `session`,
/// `cached` (the token whose SHA-256 is `cached_fingerprint`), `working` or `rejected`.
pub(super) fn login_probe(cached_fingerprint: Option<&str>) -> String {
    format!(
        ". /etc/cmux/agent-config.sh >/dev/null 2>&1\n{WORK_HOME}\n. /etc/cmux/agent-auth.sh && cmux_agent_has_own_login claude || {{ echo none; exit 0; }}\npython3 - {} {} <<'CMUX_LOGIN_PROBE' || echo working\n{PROBE_SCRIPT}\nCMUX_LOGIN_PROBE",
        quote(cached_fingerprint.unwrap_or_default()),
        quote(PROBE_ENDPOINT),
    )
}

/// Installs the Claude login staged at `payload_path` (`CloudCredentialInstaller.command`, owner guests only).
pub(super) fn install_command(payload_path: &str) -> String {
    format!(
        "set -e\n. /etc/cmux/agent-auth.sh\ncmux_agent_drop_model_plane_env\npython3 - {} {} owner <<'CMUX_CREDENTIAL_INSTALL'\n{INSTALL_SCRIPT}\nCMUX_CREDENTIAL_INSTALL",
        quote("claude"),
        quote(payload_path),
    )
}
