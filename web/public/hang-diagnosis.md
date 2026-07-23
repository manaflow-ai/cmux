# cmux hang diagnosis

Instructions for an AI coding agent (Claude Code, Codex, or similar) running in a terminal on the user's Mac. The user's cmux terminal app is hung, frozen, beachballing, or burning CPU. Follow these steps top to bottom: capture diagnostic evidence, review it with the user, and send it to the cmux team only after the user explicitly approves.

## Step 0: tell the user what will happen

Before running anything, tell the user, in your own words:

1. You will capture read-only diagnostics from the running cmux process: a process list, thread stack samples, a memory summary, and recent macOS crash/hang reports for cmux. This does not read terminal contents, shell history, or project files. Nothing is killed or restarted; cmux is left exactly as it is.
2. Everything lands in a local folder under `/tmp` that they can inspect before anything leaves the machine.
3. Nothing is uploaded without their explicit approval. The options will be: upload to `https://cmux.com/api/hang-report` (delivered by email to founders@manaflow.ai), create a secret GitHub gist on their own account, or email the archive to founders@manaflow.ai themselves.

Then start immediately. A live hang is perishable evidence: if cmux recovers or gets force-quit, the evidence is gone. Ask the user not to force-quit cmux until the capture finishes.

## Step 1: capture

Write this script to `/tmp/cmux-hang-capture.sh` and run `bash /tmp/cmux-hang-capture.sh`. It is read-only and never kills or restarts anything. If several cmux processes are running and the auto-picked one looks wrong, re-run with `CMUX_HANG_PID=<pid>`.

```bash
#!/bin/bash
# cmux hang capture: read-only evidence collection for a hung cmux.
set -u
SECS=10
OUT="/tmp/cmux-hang-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
LOG="$OUT/capture.log"
note() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# 1. Snapshot every cmux app process.
ps -axo pid=,pcpu=,pmem=,rss=,etime=,state=,args= \
  | grep '\.app/Contents/MacOS/cmux' | grep -v grep > "$OUT/cmux-processes.txt" || true
note "cmux app processes:"; tee -a "$LOG" < "$OUT/cmux-processes.txt"

# 2. Target: explicit CMUX_HANG_PID, else the highest-CPU cmux process.
PID="${CMUX_HANG_PID:-$(sort -k2 -rn "$OUT/cmux-processes.txt" | awk '{print $1; exit}')}"
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
  note "ERROR: no running cmux app process found"; exit 1
fi
APP_PATH=$(ps -o args= -p "$PID" | sed 's|\(.*\.app\)/Contents/MacOS/.*|\1|')
{
  echo "pid: $PID"
  echo "app: $APP_PATH"
  echo "version: $(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
  echo "build: $(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
  echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "captured: $(date)"
  echo "threads: $(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  ps -o pid,pcpu,pmem,rss,vsz,etime,state -p "$PID"
} > "$OUT/meta.txt" 2>&1
tee -a "$LOG" < "$OUT/meta.txt"

# 3. CPU sample: the core hang evidence. Works on fully hung processes.
note "sampling pid $PID for ${SECS}s..."
sample "$PID" "$SECS" -file "$OUT/sample.txt" >>"$LOG" 2>&1 || true
if [ ! -s "$OUT/sample.txt" ]; then
  note "NEEDS-SUDO: unprivileged sampling was blocked (normal for the notarized app)."
  note "  sudo sample $PID $SECS -file $OUT/sample.txt"
  note "  sudo spindump $PID $SECS -file $OUT/spindump.txt"
fi
if sudo -n true 2>/dev/null; then
  note "spindump (passwordless sudo available)..."
  sudo -n spindump "$PID" "$SECS" -file "$OUT/spindump.txt" >>"$LOG" 2>&1 || note "WARN: spindump failed"
fi

# 4. Memory state.
vmmap --summary "$PID" > "$OUT/vmmap-summary.txt" 2>&1 || note "WARN: vmmap failed (may need sudo)"
footprint "$PID" > "$OUT/footprint.txt" 2>&1 || true
vm_stat > "$OUT/vm_stat.txt" 2>&1

# 5. UI liveness probe through the cmux automation socket (read-only).
if command -v cmux >/dev/null 2>&1; then
  ( cmux identify --json > "$OUT/socket-probe.json" 2>>"$LOG" ) & CP=$!
  ( sleep 5; kill -TERM "$CP" 2>/dev/null ) & W=$!
  if wait "$CP" 2>/dev/null; then
    note "SOCKET RESPONSIVE (main thread is servicing requests)"
  else
    note "SOCKET UNRESPONSIVE (consistent with a blocked main thread)"
  fi
  kill -TERM "$W" 2>/dev/null; wait "$W" 2>/dev/null
fi

# 6. Recent macOS crash/hang reports for cmux.
ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i cmux | head -5 \
  > "$OUT/diagnostic-reports-recent.txt"
while IFS= read -r f; do
  [ -n "$f" ] && cp "$HOME/Library/Logs/DiagnosticReports/$f" "$OUT/" 2>/dev/null
done < "$OUT/diagnostic-reports-recent.txt"

# 7. Second CPU reading for a delta.
ps -o pid,pcpu,rss,etime,state -p "$PID" > "$OUT/ps-after.txt" 2>&1

note "=== capture complete: $OUT ==="
echo "$OUT"
```

The last line of output is the evidence folder. If the log contains `NEEDS-SUDO`, `sample.txt` is empty because macOS blocks unprivileged sampling of the notarized app. Ask the user for permission to run the two printed `sudo` commands (sudo is needed only to read the app's thread stacks), then run them in the user's interactive terminal so they can enter their password.

## Step 2: review with the user

1. List the files and sizes: `ls -lh <evidence folder>`.
2. Read `sample.txt` (or `spindump.txt`) yourself and triage. The first thread is the main thread. Parked in `mach_msg2_trap` under `CFRunLoopRun` means idle (the problem is elsewhere). Sitting in `__psynch_mutexwait`, `__psynch_cvwait`, `semaphore_wait_trap`, `__ulock_wait`, or a synchronous `dispatch` call means blocked, and the frames below it name the culprit. High CPU with a responsive socket points at a background thread; check the heaviest non-main stacks. Write a two or three sentence triage; you will include it in the report.
3. Tell the user what the files contain: stack samples hold only function names from cmux and system frameworks, `meta.txt` holds app/macOS versions and hardware model, and macOS diagnostic reports (`.ips`) can additionally include the app path and OS details. Offer to let them inspect the folder before anything is sent.

## Step 3: package

```bash
cd /tmp && tar --exclude='*.trace' -czf <evidence-folder>.tar.gz "$(basename <evidence-folder>)" && ls -lh <evidence-folder>.tar.gz
```

The upload endpoint accepts up to 3.5 MB. If the archive is larger, drop the biggest `.ips` files from the folder (keep `sample.txt`, `spindump.txt`, `meta.txt`, `capture.log`) and re-create it.

## Step 4: ask for consent, then send

Ask the user plainly, and do not upload anything until they pick one:

- **a) Upload to the cmux team** (default): sends the archive to `https://cmux.com/api/hang-report`, which emails it to founders@manaflow.ai. Include their email only if they want a reply.
- **b) Secret GitHub gist**: creates an unlisted gist of the text files on their own GitHub account (they keep control and can delete it), then sends just the gist link to the same endpoint.
- **c) Manual**: they email the archive themselves to founders@manaflow.ai.

Option a:

```bash
curl -sS -X POST https://cmux.com/api/hang-report \
  -F "archive=@/tmp/<archive>.tar.gz;type=application/gzip" \
  -F "summary=<your triage plus what the user was doing when it hung>" \
  -F "email=<user email, omit if they decline>" \
  -F "appVersion=<version from meta.txt>" \
  -F "osVersion=<macos from meta.txt>"
```

Option b (requires an authenticated `gh` CLI; gists created this way are secret/unlisted):

```bash
gh gist create -d "cmux hang report $(date +%F)" <evidence-folder>/*.txt <evidence-folder>/capture.log
curl -sS -X POST https://cmux.com/api/hang-report \
  -F "summary=<your triage plus what the user was doing when it hung>" \
  -F "gistUrl=<gist url from the previous command>" \
  -F "email=<user email, omit if they decline>"
```

A successful upload returns `{"ok":true}`. If the endpoint is unreachable, fall back to option b or c.

## Step 5: close out

1. Confirm to the user that the report was sent (or where the gist/archive is).
2. Tell them it is now safe to force-quit cmux (right-click the Dock icon while holding Option, then Force Quit) and relaunch it.
3. Give them your short triage summary so they know what the evidence showed.
