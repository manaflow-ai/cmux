# Nightly build runner toolchain drift (#21298)

The first attempt of nightly run [39005709904](https://github.com/manaflow-ai/cmux/actions/runs/39005709904)
failed before checkout on 2026-10-17 UTC. Its `build-nightly-app` job
(attempt 1, job [117321592035](https://github.com/manaflow-ai/cmux/actions/runs/39005709904/job/117321592035))
was rejected by the self-hosted Glaeda start hook:

```
glaeda-cmux-runner-hook: refused: node not eligible (toolchain drifted from the m4pro-48 class receipt: diffRustcVersion '' != 'rustc 1.88.0 (6b00bc388 2025-06-23)')
```

The failure was in `Set up runner`; checkout, Xcode selection, compilation,
and artifact production did not run. The source revision was therefore not
the cause of the incident. The retry on the same SHA passed `build-nightly-app`
and the three preparation jobs, which independently confirms that the failure
was tied to runner eligibility rather than the repository contents.

The corrective action belongs to the fleet owner: restore the Rust toolchain
receipt expected by the `m4pro-48` Glaeda class, or keep the node out of the
nightly pool until its acceptance receipt is current. No workflow routing or
production code change is needed in cmux, and no production state was changed
while investigating this incident.

Evidence was collected with:

```sh
gh run view 39005709904 --attempt 1 -R manaflow-ai/cmux --log-failed
gh run view 39005709904 --attempt 2 -R manaflow-ai/cmux --json jobs,status,conclusion
```
