# walks: minimized daemon walk failures

Each `<switch>-<seed>.json` here is a seeded daemon walk that failed on a refactor switch
(the two arms diverged, or one arm had an unexpected result), minimized with ddmin until every
step is needed for the same failure. `linux_run.sh walks REF` writes them (p15-oracle-099,
`scripts/cmux-next/oracle/walks_scale.py`): 100,000 seeds of length 30 on arm old and arm new of
every daemon switch, one build. It copies the walks here only after every failure of the run is
minimized and the report is written; commit them with the run's `receipt.json` summary.

A walk lists its switch in `switches`, so `oracle.py diff --switch NAME` refuses it as
arm-not-exercised when an arm no longer reaches the switch. The generated walks themselves are not
committed: `oracle.py gen --suite walks` makes the same walk from the same seed (p15-oracle-098).
