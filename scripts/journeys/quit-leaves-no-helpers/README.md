# Journey quit-leaves-no-helpers (P0)

Run it against a fleet build: `python3 scripts/journeys/quit-leaves-no-helpers/run.py --build JOB
[--hosts "cmux17 cmux18 cmux19 cmux21 cmux22 cmux23 cmux24"]`. It leases one capture slot, launches the
build's app, uses a terminal and an agent pane, quits it the way a person does (`quit app id`, the
Apple event of Cmd-Q, answering the quit question's default), waits 5 s, and lists every process of
the app bundle. It passes when only the documented survivors remain (journey.py says which and why).
Exit 0 pass, 1 fail, 75 not run; the record is in `artifacts/journeys/quit-leaves-no-helpers/`.

It stands alone until `cp/journeys-framework` lands (that branch's `run.py` plays JSON journeys of
keys and screen checks; this one needs process listings across a quit). It is not a CI job or gate.
