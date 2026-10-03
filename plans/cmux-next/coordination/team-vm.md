# Lane: team-vm

## Active streams
- P15 team VM (team VM lead). Plan plans/cmux-next/team-vm-plan.md draft 3: JuiceFS rejected; D36 accepted (C-BATCH); zero-loss journal in TeamVmDO (tag v13, measured 17 ms p50 Worker+DO from Freestyle); cmux-teamfs not needed. Tasks Replica targets journal.append on stream tasks (Tasks lead).

## Landed
- 2026-10-03 (this push) backend: team journal in TeamVmDO (S6): ops team_vm.journal.append|high_water|read (install principals; only the bound VM install for the current epoch), internal team_vm.bind_install, side tables journal_entry/journal_head/journal_usage (no new DO class, no tag); catalog, TS client, cmux-app-host generated files regenerated (team VM lead)
- 2026-10-03 (this push) backend: TeamVmDO (S2): binding TEAM_VM_DO, DO migration tag v10, ops team_vm.status|ensure_awake|lease.release, internal team_vm.driver_result|leases_expire, owner `cloud:TeamVmDO` keyed by team, vars TEAM_VM_SLUG_PREFIX (dev/staging cmuxnp-dev-tvm-), optional FREESTYLE_API_KEY/FREESTYLE_API_URL/TEAM_VM_SNAPSHOT (unset = not configured, creates nothing); HARD: no production FREESTYLE_API_KEY before the plan gate (S2b), and production refuses provider calls with team_vm.plan_gate_missing until S2b flips PRODUCTION_PLAN_GATE_LANDED; catalog, TS client and cmux-app-host generated files regenerated (team VM lead)
- 2026-10-03 (this push) plans: team-vm-plan.md draft 3 (DO journal store, slices S6/S7/S9/S11/S14 rewritten) (team VM lead)
- 2026-10-03 (this push) plans: team-vm-spike.md (phase A numbers) and scripts/cmux-next/team-vm-spike/ (spike scripts, no runtime code); team-vm-plan.md draft 2 (team VM lead)
- 2026-10-03 8af4bc96a00 plans: team-vm-plan.md (P15 slice order, spike design, ownership) (team VM lead)
