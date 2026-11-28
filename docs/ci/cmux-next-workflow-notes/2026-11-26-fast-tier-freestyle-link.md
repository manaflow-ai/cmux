# fast-tier-cargo: the Freestyle link check

Above fast-tier-cargo's first steps in `.github/workflows/cmux-next.yml`: the Freestyle link check.

Freestyle runners (`fsr-*`) carry the shared Linux labels, so the linux_8 pool hands them this job. On
2026-11-26 07:52Z to 08:53Z, 90 fast-tier-cargo jobs ran there and none passed (41 failed, 49 cancelled at the
30-minute job timeout); the 32 passes were all on pool runners, whose checkout took 18 to 74 s. On Freestyle the
checkout from github.com took 7 to 23 minutes (`fatal: ... Operation too slow`, then a retry that hung, job
139761062609), and apt, zig, rustup and the R2 restores after it were each minutes long too (job 139765026748),
so a job that got through its checkout still ran out of time in the build. The runners' pack source list was
missing (`checkout_pack` fallback "no source list"), so every fetch went to github.com.

The checkout is bounded at 6 minutes (note-stall-step-bounds); on a Freestyle runner a checkout over 180 s stops the job with the
cause named: that link cannot finish the job in 30 minutes, so it fails in minutes instead of burning half an
hour. A Freestyle runner with a fast link runs the job as before; pool runners are unchanged.
