import fcntl, hashlib, json, os, pathlib, pwd, stat, sys, tempfile
provider, source = sys.argv[1:3]
kinds = set((sys.argv[3] if len(sys.argv) > 3 else 'owner').split(',')) & {'owner', 'team'}
account = sys.argv[4] if len(sys.argv) > 4 else ''
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
# The image's model-plane stub values (agent-auth.sh cmux_agent_drop_model_plane_env): its placeholder key and
# its CodeRouter or team endpoint. A settings env holding only these is no custom endpoint, and they are dropped
# from it, so the own login never goes to the model plane.
stub_key = 'cmux-vm-edge-placeholder'
stub_urls = {u.rstrip('/') for u in (os.environ.get('CMUX_CODEROUTER_URL'), os.environ.get('CMUX_CLAUDE_TEAM_BASE_URL')) if u}
def stub(env, k):
    v = env.get(k)
    if k == 'ANTHROPIC_API_KEY': return v == stub_key
    if k == 'ANTHROPIC_BASE_URL':
        return isinstance(v, str) and (v.rstrip('/') in stub_urls or (not stub_urls and env.get('ANTHROPIC_API_KEY') == stub_key))
    return False
def digest(text): return hashlib.sha256(text.encode()).hexdigest()
def installed(provider):
    # The login this machine holds now, as a digest (never the login itself), or None.
    try:
        if provider == 'claude':
            token = json.loads((home / '.claude/settings.json').read_text()).get('env', {}).get('CLAUDE_CODE_OAUTH_TOKEN')
            return digest(token) if isinstance(token, str) and token else None
        return digest(json.dumps(json.loads((home / '.codex/auth.json').read_text())))
    except Exception:
        return None
try:
    # Custom endpoints/keys must never receive the transferred subscription credential.
    conflicts = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                 'CLAUDE_CONFIG_DIR', 'OPENAI_BASE_URL', 'CODEX_HOME', 'CODEX_API_KEY']
    if any(os.environ.get(k) for k in conflicts): raise ValueError()
    if os.environ.get('CMUX_' + provider.upper() + '_AUTH') == 'team': raise ValueError()
    value = source.read_text()
    marks = home / '.config/cmux/agent-auth'
    private_dir(marks)
    # One install at a time on a machine: a second copy (another Mac, or a spare-ready copy beside a claim's)
    # waits, then finds the first one's login and leaves it.
    lock = os.open(marks / ('.' + provider + '.install.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)
    mark = marks / (provider + '.login')
    if mark.is_symlink(): raise ValueError()
    try: prior = json.loads(mark.read_text()) if mark.exists() else {}
    except Exception: prior = {}
    wanted = digest(value if provider == 'claude' else json.dumps(json.loads(value)))
    held = installed(provider)
    # The same account's same login, still in place and chosen: nothing to do, and success.
    if (held == wanted and prior.get('digest') == wanted and prior.get('account', '') == account
            and (marks / provider).is_file() and (marks / provider).read_text().strip() == 'own'):
        sys.exit(0)
    if provider == 'claude':
        settings = home / '.claude/settings.json'
        if settings.is_symlink(): raise ValueError()
        config = json.loads(settings.read_text()) if settings.exists() else {}
        env = config.setdefault('env', {})
        if 'apiKeyHelper' in config or any(env.get(k) and not stub(env, k) for k in conflicts): raise ValueError()
        for k in [k for k in conflicts if stub(env, k)]: env.pop(k)
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
    save(mark, json.dumps({'account': account, 'digest': wanted}))
except Exception:
    sys.exit(72)
finally:
    source.unlink(missing_ok=True)
