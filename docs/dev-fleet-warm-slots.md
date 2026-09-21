# Dev-fleet warm build slots

Issue #13091 measures a development-only optimization: keep an idle Mac build slot warm at a recent compatible main generation, then start a new agent task from that exact warm source. The task still runs its normal native build. Hosted CI, merge groups, signing, release builds, and required checks keep their existing source decisions.

The worker-side prototype is scripts/dev-fleet-warm-slot.py. The reproducible physical benchmark is scripts/benchmark-dev-fleet-warm-slots.py.

## Source handoff

This experiment uses an explicit generation receipt instead of a dedicated warm-main branch.

A warm generation records:

- the exact accepted Git commit and tree;
- the exact commit that completed the last native warm build;
- a conservative macOS build-input fingerprint;
- the selected Xcode/Swift/SDK/architecture identity;
- a persistent cache-lineage id and DerivedData path;
- whether that lineage is warm-ready or quarantined.

Task creation asks task-base for a compatible generation. That command first publishes foreground demand, waits for the slot, then leaves a durable `reserved-task` lease containing `lease_id`, `base_commit`, and `warm_generation_id`. By default the accepted base may trail authoritative main by at most three first-parent commits; an experiment can set `--max-main-distance` explicitly. Unknown or older distance falls back cold. The task branches from that exact source while the reservation prevents the warmer from changing the slot. `task-run` must present the same lease/generation pair before it can consume warm state. Authoritative main can continue moving independently, and CI continues validating its current main or merge-group source.

This removes a synchronization job from Git refs. The default input proof is the complete tracked Git tree, so any tree change schedules a native warm build. Only an identical tree can advance source metadata without Xcode. A narrower skip policy belongs behind a project-owned, measured input declaration; uncertainty always rebuilds.

## Machine-local safety contract

State lives under a controller-selected machine directory. No hostname or personal machine is embedded in the policy.

Example layout:

    <machine-state>/
      warmer.lock
      warmer-preempt.fifo
      foreground.lock
      foreground/
      checkout-locks/
      events.jsonl
      slots/<slot>/
        slot.lock
        lease.json
        inflight.json
        slot.json
        cache/
        logs/
        recovery/

The contract is:

- Every warm or task build owns slot.lock and publishes lease.json while it owns the slot. `task-base` also leaves a bounded durable reservation across branch creation; the build upgrades that same lease ID.
- The physical machine has one warmer.lock, so at most one background warmer executes per Mac.
- A task reservation or task build holds a shared machine foreground gate before waiting for slot.lock. New foreground demand writes the warmer FIFO, so preemption is event-driven instead of polling request files.
- Slots that point at the same physical checkout share a checkout lock across source switching and native execution. Separate slot checkouts can still proceed independently.
- The warmer lowers its process priority with nice(15). Foreground task builds keep normal priority.
- Dirty source quarantines a warm lineage. Source movement uses clean detached Git switches; the helper never runs git reset.
- Xcode/toolchain changes make the prior generation cold.
- A task miss, stale generation, or unprovable main distance gets the cold path; task builds use isolated cold DerivedData and still run the complete native build.
- Dirty/unavailable/recovery-required source returns cold_fallback_required so the controller can use its existing clean exact-SHA lane.
- A successful task build that consumed the shared warm lineage marks it warm_ready=false. The slot must be warmed back to main before it can advertise another task base.
- Reservations expire after a bounded lease interval. An abandoned task can release its exact lease explicitly; mismatched task/lease IDs fail closed.

The helper writes inflight.json before launching native work. A pipe launch guard keeps the child from executing the native command until its process group is durably recorded in both the in-flight record and visible lease. SIGINT/SIGTERM is forwarded to that group. If the helper dies unexpectedly, the guarded child exits before native exec or recover uses the exact recorded run/group identity. Recovery quarantines the lineage; diagnostic request records also carry process-start identity so PID reuse cannot keep a slot falsely busy.

## Conservative build-input classification

The default build-input fingerprint covers the complete tracked Git tree. Any tree change, including docs or platform-specific paths, schedules a native warm build. This deliberately spends extra background work until the project can provide a stronger complete input declaration.

The classifier only decides whether the background warmer can advance a source receipt without executing Xcode. It never skips a task build. Swift/Xcode remain responsible for compiler-level incremental correctness. Glaeda preparation inputs are the preferred future place to narrow dependency-readiness work once the cmux native profile declares the full relevant set.

## Worker recipe

The default native command is the existing tagged reload helper and an owned DerivedData path:

    python3 scripts/dev-fleet-warm-slot.py warm \
      --machine-state "$CMUX_FLEET_MACHINE_STATE" \
      --slot "$CMUX_FLEET_SLOT" \
      --checkout "$CMUX_FLEET_CHECKOUT" \
      --target "$MAIN_SHA" \
      --tag "warm-$CMUX_FLEET_SLOT-main"

Before creating a task:

    python3 scripts/dev-fleet-warm-slot.py task-base \
      --machine-state "$CMUX_FLEET_MACHINE_STATE" \
      --slot "$CMUX_FLEET_SLOT" \
      --checkout "$CMUX_FLEET_CHECKOUT" \
      --authoritative-main "$MAIN_SHA" \
      --task-id "$TASK_ID" \
      --receipt "$TASK_GENERATION_RECEIPT"

The controller stores base_commit, warm_generation_id, and lease_id from that receipt, creates the task branch from base_commit, and later validates the task through task-run while presenting the exact reservation:

    python3 scripts/dev-fleet-warm-slot.py task-run \
      --machine-state "$CMUX_FLEET_MACHINE_STATE" \
      --slot "$CMUX_FLEET_SLOT" \
      --checkout "$CMUX_FLEET_CHECKOUT" \
      --target "$TASK_SHA" \
      --task-id "$TASK_ID" \
      --lease-id "$WARM_SLOT_LEASE_ID" \
      --warm-generation-id "$WARM_GENERATION_ID" \
      --receipt "$TASK_BUILD_RECEIPT"

If task creation is abandoned before the build starts, release the exact reservation:

    python3 scripts/dev-fleet-warm-slot.py release \
      --machine-state "$CMUX_FLEET_MACHINE_STATE" \
      --slot "$CMUX_FLEET_SLOT" \
      --task-id "$TASK_ID" \
      --lease-id "$WARM_SLOT_LEASE_ID"

The worker can inspect a decision without mutation:

    python3 scripts/dev-fleet-warm-slot.py explain ...

Recovery uses the exact durable run id:

    python3 scripts/dev-fleet-warm-slot.py recover \
      --machine-state "$CMUX_FLEET_MACHINE_STATE" \
      --slot "$CMUX_FLEET_SLOT" \
      --run-id "$RUN_ID"

## Glaeda native Apple execution

teamleaderleo/glaeda#1048 provides the useful native primitives for this lane: persistent project/toolchain cache lineage, a project build lock, exact commit/tree/clean-source admission for direct execution, dependency-readiness reuse, read-only plan/explain output, and explicit interrupted-generation recovery/quarantine.

cmux PR #13383 is separately consuming that work for a compile-admission pilot. This dev-fleet experiment does not change CI routing or make that pilot a prerequisite.

The warm-slot helper accepts an explicit native command after --, so the controller can switch the worker executor to Glaeda once the cmux native Apple profile lands. The slot generation remains the scheduling/source receipt; Glaeda can own the lower-level cache lineage, dependency preparation, native serialization, and recovery. Keeping those roles separate avoids a second compiler cache and avoids retaining warm-main solely for coordination.

A Glaeda-backed recipe should bind the exact target commit/tree and require clean source for the warm/task invocation. It should keep native validation enabled on every task build.

## Physical benchmark

First pin the exact first-parent source cases:

    python3 scripts/benchmark-dev-fleet-warm-slots.py discover \
      --checkout /path/to/cmux \
      --main origin/main \
      --behind 3 \
      --output /tmp/cmux-warm-manifest.json

Then run on any eligible dev-fleet Mac with a new output directory:

    python3 scripts/benchmark-dev-fleet-warm-slots.py run \
      --checkout /path/to/cmux \
      --manifest /tmp/cmux-warm-manifest.json \
      --output /private/tmp/cmux-warm-trial

If a second installed Xcode is available, add:

    --alternate-developer-dir /Applications/Xcode-other.app/Contents/Developer

The matrix covers:

1. a cold new slot;
2. an exact-base warm slot;
3. a slot one/few first-parent main commits behind;
4. a pinned source-only change;
5. a pinned package/project graph change;
6. an actual toolchain switch when a second Xcode is supplied;
7. a warmer interrupted by a foreground task.

The run restores the original clean checkout HEAD when it completes. Each case uses independent machine state so one case cannot warm another.

report.json records:

- task-known to first build start;
- first task build wall time;
- SwiftCompile line count;
- warmer build time and duty cycle;
- exact/near/cold task counts and useful-hit percentage;
- foreground build/queue delta in the preemption case versus the cold case;
- cache disk growth and final state size;
- cold fallback, fallback-required, quarantine, and recovery counts.

For a longer worker trial, events.jsonl is append-only. Summarize it with:

    python3 scripts/benchmark-dev-fleet-warm-slots.py report \
      --events "$CMUX_FLEET_MACHINE_STATE/events.jsonl"

## Trial policy and kill criteria

Start with one worker/profile for 24 hours after the repo-side policy is deployed. The current controller background-duty allowance is a ceiling, not a target. Real task demand always wins.

Keep or broaden the warmer only when current worker measurements show frequent exact/near hits, a large first-build improvement, and negligible foreground delay. Narrow the warmed profiles or cadence when useful hits are sparse. Drop background warming when it consumes meaningful machine time or disk while most tasks still receive cold state, or when preemption adds material real-work delay.

The old measurements in #13091 remain historical evidence. The benchmark above exists so policy decisions use a current worker-class matrix before expanding the experiment.
