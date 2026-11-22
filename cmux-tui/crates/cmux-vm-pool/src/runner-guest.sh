#!/bin/bash
# The guest half of a freestyle-runners VM (runners.mjs runs it as root over exec; freestyle_runners.py has the flow).
#
# This is cmux-vm-pool's copy (`cmux vm runner`), taken from cmuxterm-hq tools/freestyle-workflow/runner-guest.sh at
# lane/freestyle-reuse-parked (hq#17192). Keep the shared verbs (prepare, prepare-bg, prepare-result, reset, start)
# identical to hq's. Two additions here: `start-direct`, and a job-started hook wrapper that records which job
# took the runner (no secrets) for `cmux vm runner new --wait`.
#
#   runner-guest.sh prepare VERSION SHA256   install the runner and its user, make this VM's key pair, print the cert
#   runner-guest.sh prepare-bg VERSION SHA256  the same, detached; prepare-result reads it (75 while it runs)
#   runner-guest.sh start                     stdin: the JIT config sealed to that cert; open it, start the runner
#   runner-guest.sh start-direct NAME        stdin: the plain JIT config (`cmux vm runner new`: one process holds both
#                                             the Freestyle key and the user's GitHub credential, over TLS, so nothing
#                                             is sealed); it goes to the runner's environment, never argv or a file
#   runner-guest.sh reset                     a parked VM brought back (runners.mjs reuseOne): clear what its last
#                                             prepare and job left, so prepare-bg runs again and makes a new key pair
#
# The private key never leaves the VM and is removed once the config is open. The runner reads its one-job config
# from the environment (ACTIONS_RUNNER_INPUT_JITCONFIG), never argv. The guest powers off after the job, while the
# provider retains the VM for a later reconciliation.
set -uo pipefail
if [[ $OSTYPE == darwin* ]] && ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501)); then BASH_COMPAT=50; fi  # macOS heredoc pipe hang: tests/test_bash_heredoc_pipe_guard.py
# FSR_ROOT: a prefix for the tests (runners.test.mjs runs reset in a temporary directory); empty on a VM.
root="${FSR_ROOT:-}"
state=$root/var/lib/fsr
runner_home=$root/home/runner
dir=$runner_home/actions-runner
fail() { echo "runner-guest: $1" >&2; exit 1; }

# No background apt on a runner (cmux#48681). At boot, unattended-upgrades (apt-daily-upgrade.service) held the dpkg
# lock while a job ran `apt-get install`, and the job failed "Could not get lock ... held by process N (unattended-upgr)"
# (cmux runs 44874872145, 44875944103). So: stop the apt timers and their services (the stop waits while
# unattended-upgrade finishes the package it is on), mask them and unattended-upgrades for every later boot, and make
# every apt call on this machine, ours and every job's, wait up to 300 s for the lock instead of failing. Idempotent: it
# runs at every boot.
apt_conf=$root/etc/apt/apt.conf.d
quiet_apt() {
  local units="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service"
  # shellcheck disable=SC2086  # units is a word list
  timeout 300 systemctl stop $units >/dev/null 2>&1
  # shellcheck disable=SC2086
  systemctl mask $units unattended-upgrades.service >/dev/null 2>&1
  mkdir -p "$apt_conf" && echo 'DPkg::Lock::Timeout "300";' > "$apt_conf/99-cmux-dpkg-lock-timeout"
}

# A Freestyle runner takes the GCP one-job labels. Keep its package set in sync (test_freestyle_runners.ImageContract).
PACKAGES="curl ca-certificates git jq openssl unzip zstd python3 sudo git-lfs zip xz-utils build-essential pkg-config \
golang-go cargo rustc python3-venv python3-pip python3-pytest rsync bison ruby clang cmake libssl-dev openjdk-17-jdk-headless"

prepare() {
  local ver="$1" sha="$2"
  case "$ver" in *[!0-9.]*|'') fail "bad runner version";; esac
  case "$sha" in *[!0-9a-f]*|'') fail "bad runner checksum";; esac
  ( umask 077; mkdir -p "$state" ) || fail "no state dir"
  local archive="$state/runner.tar.gz"
  local sudoers="$root/etc/sudoers.d/runner" hook=/usr/local/bin/fsr-fork-guard.sh
  [[ -f "$root$hook" && -s "$root$hook" ]] && chmod 755 "$root$hook" || fail "missing runner fork guard"
  quiet_apt
  export DEBIAN_FRONTEND=noninteractive
  # Query the installed packages locally: a warm disk needs no apt update and a package removed by a job is repaired.
  # shellcheck disable=SC2086  # each package name is a separate argument
  if ! dpkg-query -W -f='${db:Status-Status}\n' $PACKAGES | awk '$0 != "installed" {bad=1} END {exit bad || !NR}'; then
    apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends $PACKAGES >/dev/null ||
      echo "runner-guest: package install failed; continuing" >&2
  fi
  # Keep gh separate so an image without the optional gh package can still install everything else.
  command -v gh >/dev/null || apt-get install -y -qq --no-install-recommends gh >/dev/null 2>&1 ||
    echo "runner-guest: no gh package" >&2
  for t in curl openssl tar sha256sum runuser; do command -v "$t" >/dev/null || fail "no $t"; done
  id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner || fail "no runner user"
  # useradd makes the cold guest's home. Reset removed the previous job's home on a warm guest.
  [[ -d "$runner_home" ]] || install -d -m 0750 -o runner -g runner "$runner_home" || fail "no runner home"
  getent group docker >/dev/null && usermod -aG docker runner
  echo 'runner ALL=(ALL) NOPASSWD:ALL' > "$sudoers.tmp" && chmod 440 "$sudoers.tmp" && mv -f "$sudoers.tmp" "$sudoers" || fail "no runner sudoers entry"
  mkdir -p "$dir" && cd "$dir" || fail "no runner dir"
  if ! [[ -f "$archive" ]] || ! echo "$sha  $archive" | sha256sum -c --status -; then
    curl -fsSL --retry 5 -o "$archive.tmp" \
      "https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-x64-$ver.tar.gz" ||
      fail "runner download failed"
    echo "$sha  $archive.tmp" | sha256sum -c --status - || fail "runner checksum mismatch"
    mv -f "$archive.tmp" "$archive" || fail "could not cache verified runner"
  fi
  tar xzf "$archive" || fail "runner unpack failed"
  if [[ ! -f "$state/dependencies.sha256" || "$(< "$state/dependencies.sha256")" != "$sha" ]]; then
    if ./bin/installdependencies.sh >/dev/null 2>&1; then
      printf '%s\n' "$sha" > "$state/dependencies.sha256"
    else
      echo "runner-guest: installdependencies failed" >&2
    fi
  fi
  # The hosted runners' work dir (gha_runners.py WORK_FOLDER, the JIT config's work_folder).
  install -d -o runner -g runner "$root/home/runner/work" || fail "no work dir"
  # The job-started hook records the job's repository, run and name (no secrets) in /tmp/fsr-job, then runs the fork guard.
  cat > "$root/usr/local/bin/fsr-job-hook.sh" <<'HOOK' && chmod 755 "$root/usr/local/bin/fsr-job-hook.sh" || fail "no job hook"
#!/bin/bash
umask 022
printf 'repository %s\nrun_id %s\nrun_attempt %s\njob %s\nworkflow %s\n' "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}" \
  "${GITHUB_RUN_ATTEMPT:-}" "${GITHUB_JOB:-}" "${GITHUB_WORKFLOW:-}" > /tmp/fsr-job.tmp && mv -f /tmp/fsr-job.tmp /tmp/fsr-job
exec /usr/local/bin/fsr-fork-guard.sh "$@"
HOOK
  printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "$root/usr/local/bin/fsr-job-hook.sh" > "$dir/.env" || fail "could not configure runner fork guard"
  # JDK 17 under the names hosted images give it (JAVA_HOME_17_X64, JAVA_HOME), in the runner's .env, as runner-startup.sh
  # and pool.sh do; only a JDK whose java and javac run here is named.
  jdk17="$root/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture 2>/dev/null)"
  if "$jdk17/bin/java" -version >/dev/null 2>&1 && "$jdk17/bin/javac" -version >/dev/null 2>&1; then
    printf '%s\n' "JAVA_HOME_17_X64=$jdk17" "JAVA_HOME=$jdk17" >> "$dir/.env"
  else
    echo "runner-guest: JDK 17 missing or not runnable at $jdk17; jobs that select JDK 17 fail" >&2
  fi
  chown -R runner:runner "$dir" || fail "could not set runner ownership"
  openssl req -x509 -newkey rsa:3072 -nodes -keyout "$state/key.pem" -out "$state/cert.pem" -days 2 \
    -subj "/CN=$(hostname)" >/dev/null 2>&1 || fail "no key pair"
  cat "$state/cert.pem"
}

# A reused VM (runners.mjs reuseOne) booted again after its one job powered it off. Clear its last lifecycle: prepare's
# markers (prepare-bg refuses while they exist), the old key pair (start removes the key, but a VM whose runner never
# started keeps it), the opened config and run script, the old runner's registration (.runner, .credentials*) and
# logs, and the whole job user's home (installation, workspace, credentials and dotfiles). The root-owned marker and verified
# runner archive are reused by prepare. Refused while a prepare from this boot still runs.
reset() {
  if [ -s "$state/prepare.pid" ]; then
    local pid; pid="$(cat "$state/prepare.pid")"
    case "$pid" in *[!0-9]*|'') ;; *)
      if [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'runner-guest.sh prepare'; then
        fail "prepare still running (pid $pid)"
      fi ;;
    esac
  fi
  # Return the previous registration's fixed-format timestamps before clearing its files.
  if [ -f "$state/timing" ]; then
    head -c 1024 "$state/timing" | LC_ALL=C sed -nE '/^runner fsr-[A-Za-z0-9_-]{1,100}$/p; /^(runner_online|job_assigned|park_requested) [0-9T:Z.+-]{20,30}$/p'
  fi
  rm -f "$state"/prepare.pid "$state"/prepare.rc "$state"/prepare.rc.tmp "$state"/prepare.out "$state"/prepare.err \
    "$state"/key.pem "$state"/cert.pem "$state"/jit "$state"/run.sh "$state"/run.sh.tmp "$state"/started "$state"/parking "$state"/runner.log "$state"/timing /tmp/fsr-job /tmp/fsr-job.tmp || fail "could not clear $state"
  rm -rf -- "$runner_home" || fail "could not clear the last runner home"
  echo "runner-guest: reset"
}

# prepare outlives one exec (exec-await's 300 s cap; runners.mjs prepareDetached): prepare-bg starts it detached
# and returns at once; prepare-result exits 75 while it runs, else prepare's own status with its output.
prepare_bg() {
  ( umask 077; mkdir -p "$state" ) || fail "no state dir"
  [ -e "$state/prepare.rc" ] || [ -e "$state/prepare.pid" ] && fail "prepare already started"
  nohup setsid bash -c 'bash "$0" prepare "$1" "$2" > "$3/prepare.out" 2> "$3/prepare.err"; echo $? > "$3/prepare.rc.tmp" &&
    mv "$3/prepare.rc.tmp" "$3/prepare.rc"' "$(readlink -f "$0")" "$1" "$2" "$state" < /dev/null > /dev/null 2>&1 &
  echo $! > "$state/prepare.pid"
  echo "runner-guest: prepare started"
}

prepare_result() {
  [ -e "$state/prepare.pid" ] || fail "prepare not started"
  [ -s "$state/prepare.rc" ] || exit 75
  cat "$state/prepare.out"
  tail -c 2000 "$state/prepare.err" >&2
  exit "$(cat "$state/prepare.rc")"
}

start() {
  local name="${1:-}" jit
  exec 9>"$state/start.lock" && flock -w 20 9 || fail "could not lock runner start"
  if [[ -f "$state/started" ]]; then
    [[ "$(< "$state/started")" == "$name" ]] || fail "another runner generation already started"
    echo "runner-guest: runner already started"
    return 0
  fi
  [[ ! -e "$state/parking" ]] || fail "runner is parking"
  [[ ! -e "$state/run.sh" ]] || fail "previous runner launch outcome unknown"
  [ -s "$state/key.pem" ] || fail "no key (prepare first, once)"
  jit="$(openssl cms -decrypt -inform PEM -inkey "$state/key.pem")" || fail "could not open the config"
  [ -n "$jit" ] || fail "empty config"
  ( umask 077; printf '%s' "$jit" > "$state/jit" ) && chown runner:runner "$state/jit" || fail "no config file"
  unset jit
  printf 'runner %s\n' "$name" > "$state/timing" || fail "could not record runner name"
  # One job, then power off. setsid + nohup: the exec that started it returns at once. The VM remains retained.
  cat > "$state/run.sh.tmp" <<'RUN' || fail "could not write runner script"
#!/bin/bash
cd /home/runner/actions-runner || exit 1
export ACTIONS_RUNNER_INPUT_JITCONFIG="$(cat /var/lib/fsr/jit)"
rm -f /var/lib/fsr/jit
runuser -u runner -- ./run.sh 2>&1 | tee /var/lib/fsr/runner.log | LC_ALL=C sed -unE \
  -e 's/^([0-9-]{10}) ([0-9:]{8}Z): Listening for Jobs.*/runner_online \1T\2/p' \
  -e 's/^([0-9-]{10}) ([0-9:]{8}Z): Running job:.*/job_assigned \1T\2/p' >> /var/lib/fsr/timing
echo "runner exited ${PIPESTATUS[0]}" >> /var/lib/fsr/runner.log
date -u '+park_requested %Y-%m-%dT%H:%M:%SZ' >> /var/lib/fsr/timing
systemctl poweroff || poweroff -f
RUN
  chmod 700 "$state/run.sh.tmp" && mv -f "$state/run.sh.tmp" "$state/run.sh" || fail "could not publish runner script"
  rm -f "$state/key.pem" || fail "could not remove key"
  nohup setsid "$state/run.sh" 9>&- >/dev/null 2>&1 < /dev/null &
  printf '%s\n' "$name" > "$state/started" || fail "could not record runner launch"
  echo "runner-guest: runner started"
}

# `cmux vm runner new`: the plain JIT config on stdin, from one process that holds the Freestyle key and the user's
# GitHub credential over TLS (no hq seal step). It is handed to the runner through its environment: no argv, no file.
start_direct() {
  local name="${1:-}" jit
  case "$name" in fsr-[A-Za-z0-9_-]*) ;; *) fail "bad runner name";; esac
  exec 9>"$state/start.lock" && flock -w 20 9 || fail "could not lock runner start"
  if [[ -f "$state/started" ]]; then
    [[ "$(< "$state/started")" == "$name" ]] || fail "another runner generation already started"
    echo "runner-guest: runner already started"
    return 0
  fi
  [[ ! -e "$state/parking" ]] || fail "runner is parking"
  [[ ! -e "$state/run.sh" ]] || fail "previous runner launch outcome unknown"
  jit="$(cat)"
  [ -n "$jit" ] || fail "empty config"
  printf 'runner %s\n' "$name" > "$state/timing" || fail "could not record runner name"
  cat > "$state/run.sh.tmp" <<'RUN' || fail "could not write runner script"
#!/bin/bash
cd /home/runner/actions-runner || exit 1
runuser -u runner -- ./run.sh 2>&1 | tee /var/lib/fsr/runner.log | LC_ALL=C sed -unE \
  -e 's/^([0-9-]{10}) ([0-9:]{8}Z): Listening for Jobs.*/runner_online \1T\2/p' \
  -e 's/^([0-9-]{10}) ([0-9:]{8}Z): Running job:.*/job_assigned \1T\2/p' >> /var/lib/fsr/timing
echo "runner exited ${PIPESTATUS[0]}" >> /var/lib/fsr/runner.log
date -u '+park_requested %Y-%m-%dT%H:%M:%SZ' >> /var/lib/fsr/timing
systemctl poweroff || poweroff -f
RUN
  chmod 700 "$state/run.sh.tmp" && mv -f "$state/run.sh.tmp" "$state/run.sh" || fail "could not publish runner script"
  rm -f "$state/key.pem"
  ACTIONS_RUNNER_INPUT_JITCONFIG="$jit" nohup setsid "$state/run.sh" 9>&- >/dev/null 2>&1 < /dev/null &
  unset jit
  printf '%s\n' "$name" > "$state/started" || fail "could not record runner launch"
  echo "runner-guest: runner started"
}

case "${1:-}" in
  prepare) [ $# -eq 3 ] || fail "usage: prepare VERSION SHA256"; prepare "$2" "$3" ;;
  prepare-bg) [ $# -eq 3 ] || fail "usage: prepare-bg VERSION SHA256"; prepare_bg "$2" "$3" ;;
  prepare-result) prepare_result ;;
  start) start "${2:-}" ;;
  start-direct) start_direct "${2:-}" ;;
  reset) reset ;;
  *) fail "usage: runner-guest.sh prepare|prepare-bg VERSION SHA256 | prepare-result | start | start-direct NAME | reset" ;;
esac
