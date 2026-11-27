"""Import a complete controller timing inventory; never infer migration savings."""
import json
from pathlib import Path

from benchlib.bench import Bench, BenchError


class CIMacMinutes(Bench):
    name = "ci-mac-minutes"
    summary = "Observed CI duration by workflow, job and runner OS, with unknowns retained"
    units = "min, count"
    owner = "CI Linux routing"
    hosts = ("anywhere", "local-readonly")
    harness = "scripts/measure/ci-mac-minutes.py"
    version = "1"

    def run(self, ctx):
        raise BenchError("Pass --import REPORT.json from ci-mac-minutes.py with a completion manifest")

    def ingest(self, ctx, path):
        report = json.loads(Path(path).read_text())
        if report.get("coverage") != "exporter reports complete; window and count verified":
            raise BenchError("Timing inventory is incomplete or its coverage is unknown")
        ctx.notes.append(f"Completed jobs in [{report['since']}, {report['until']}); not proven savings")
        for group in report["inventory"]:
            labels = {"repo": report["repo"], "workflow": group["workflow"],
                      "job": group["job"], "os": group["os"],
                      "window_seconds": report["until"] - report["since"]}
            ctx.row("jobs", group["jobs"], "count", better="none", labels=labels)
            ctx.row("untimed_jobs", group["untimed_jobs"], "count", better="none", labels=labels)
            if group["untimed_jobs"]:
                ctx.notes.append(f"{group['workflow']}/{group['job']}: incomplete duration; minutes omitted")
            else:
                ctx.row("job_minutes", group["minutes"], "min", better="none", labels=labels)


BENCH = CIMacMinutes()
