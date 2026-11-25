# cmux-migrate SSH host probe: `ssh HOST sh -s < probe`. Read-only, bounded, prints one JSON
# object per line ({"t":KIND,...}, every value a string) and never a file's contents.
# Every command reads /dev/null, so none eats the script from `sh -s`.
# Facts: os, cpu/mem, disk, toolchains, git checkouts under $HOME (depth <= 4, <= 200), each
# repo's lockfiles, dotfile and agent-state sizes, running services, listening ports, crontab size.
LC_ALL=C
export LC_ALL
H=${HOME:-}
[ -n "$H" ] || H=$(cd ~ 2>/dev/null && pwd)

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
emit() {
  _l="{\"t\":\"$(esc "$1")\""
  shift
  while [ $# -ge 2 ]; do
    _l="$_l,\"$(esc "$1")\":\"$(esc "$2")\""
    shift 2
  done
  printf '%s}\n' "$_l"
}
if command -v timeout >/dev/null 2>&1; then
  b() { _s=$1; shift; timeout "$_s" "$@" </dev/null; }
else
  b() { shift; "$@" </dev/null; }
fi
have() { command -v "$1" >/dev/null 2>&1; }
kib() { b 20 du -sk "$1" 2>/dev/null | awk '{print $1 * 1024; exit}'; }
rel() { case $1 in "$H"/*) printf '~/%s' "${1#"$H"/}" ;; *) printf '%s' "$1" ;; esac; }

# The machine.
os=$(uname -s 2>/dev/null)
arch=$(uname -m 2>/dev/null)
distro=
if [ -r /etc/os-release ]; then
  distro=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | tr -d '"')
elif have sw_vers; then
  distro="macOS $(sw_vers -productVersion 2>/dev/null)"
fi
emit os os "$os" arch "$arch" distro "$distro"

cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)
mem=
if [ -r /proc/meminfo ]; then
  mem=$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)
elif have sysctl; then
  mem=$(sysctl -n hw.memsize 2>/dev/null)
fi
emit cpu cpus "$cpus" mem_bytes "$mem"

df_line=$(b 10 df -Pk "$H" 2>/dev/null | awk 'NR == 2 {print $2 * 1024, $3 * 1024}')
emit disk total_bytes "${df_line%% *}" used_bytes "${df_line##* }" home_bytes "$(kib "$H")"

# Toolchains: the first line of each version.
for tool in node python3 python go rustc cargo docker nix mise bun deno java ruby; do
  have "$tool" || continue
  case $tool in
    go) v=$(b 5 go version 2>/dev/null | head -n 1) ;;
    java) v=$(b 5 java -version 2>&1 | head -n 1) ;;
    *) v=$(b 5 "$tool" --version 2>/dev/null | head -n 1) ;;
  esac
  emit tool name "$tool" version "$v"
done

# Git checkouts under $HOME: a folder with .git, at most 4 levels down, at most 200.
if have git; then
  b 30 find "$H" -maxdepth 5 \
    \( -name node_modules -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup \
       -o -name Library -o -name .Trash -o -name .venv -o -name venv -o -name target \
       -o -name .local -o -name snap \) -prune -o \
    -name .git -print -prune 2>/dev/null | head -n 200 | while IFS= read -r g; do
    d=${g%/.git}
    url=$(b 5 git -C "$d" remote get-url origin 2>/dev/null)
    if [ -z "$url" ]; then
      first=$(b 5 git -C "$d" remote 2>/dev/null | head -n 1)
      [ -n "$first" ] && url=$(b 5 git -C "$d" remote get-url "$first" 2>/dev/null)
    fi
    # Never a login or token from the URL.
    url=$(printf '%s' "$url" | sed 's#://[^/@]*@#://#')
    branch=$(b 5 git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
    commit=$(b 5 git -C "$d" rev-parse HEAD 2>/dev/null)
    dirty=$(b 15 git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    unpushed=$(b 10 git -C "$d" rev-list --count '@{u}..' 2>/dev/null)
    [ -n "$unpushed" ] || unpushed=$(b 10 git -C "$d" rev-list --count HEAD --not --remotes 2>/dev/null)
    files=
    for f in package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock Cargo.lock go.mod \
      go.sum requirements.txt pyproject.toml poetry.lock uv.lock Pipfile.lock Gemfile.lock \
      composer.lock mix.lock .tool-versions mise.toml .mise.toml .nvmrc .node-version \
      .python-version rust-toolchain.toml rust-toolchain .devcontainer/devcontainer.json \
      .devcontainer.json docker-compose.yml docker-compose.yaml compose.yml compose.yaml \
      flake.nix shell.nix devbox.json .gitpod.yml .cmux/machine.toml Makefile justfile; do
      [ -e "$d/$f" ] && files="$files${files:+,}$f"
    done
    emit repo path "$(rel "$d")" url "$url" branch "$branch" commit "$commit" dirty "$dirty" \
      unpushed "$unpushed" bytes "$(kib "$d")" files "$files"
  done
fi

# Dotfiles and agent state: presence and size only. Logins are named, never read.
for p in .zshrc .bashrc .profile .gitconfig .claude .codex .config/nvim .ssh/config \
  .claude/.credentials.json .codex/auth.json; do
  [ -e "$H/$p" ] || continue
  if [ -d "$H/$p" ]; then kind=dir; else kind=file; fi
  emit dotfile path "~/$p" kind "$kind" bytes "$(kib "$H/$p")"
done

# Running services.
if have systemctl; then
  b 5 systemctl --user list-units --type=service --state=running --no-legend --plain 2>/dev/null |
    awk '{print $1}' | head -n 100 | while IFS= read -r unit; do
    [ -n "$unit" ] && emit unit name "$unit"
  done
fi
if have docker; then
  b 10 docker ps --format '{{.Names}}	{{.Image}}	{{.Ports}}	{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null |
    head -n 100 | while IFS='	' read -r name image ports dir; do
    [ -n "$name" ] && emit container name "$name" image "$image" ports "$ports" dir "$(rel "$dir")"
  done
fi
if have ss; then
  b 5 ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | head -n 100 |
    while IFS= read -r port; do
      [ -n "$port" ] && emit listen port "$port"
    done
fi

if have crontab; then
  n=$(b 5 crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -c .)
  emit cron lines "${n:-0}"
fi

emit done
