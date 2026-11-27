"""Run the same landed harness on two builds using --build SHA --arg worker=MAC --arg ref=HARNESS_SHA."""
import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context


class CoordinatorCPU(Bench):
    name = "coordinator-cpu"
    summary = "Focused CEF renderer CPU with long history and twenty ticking subagents"
    units = "%"
    owner = "chat performance"
    harness = "scripts/measure/chat-open.sh"

    def run(self, ctx: Context) -> None:
        sha = ctx.build.get("sha")
        if not sha or not ctx.args.get("worker"):
            raise BenchError("coordinator-cpu needs --build SHA and --arg worker=MAC")
        result = ctx.fleet_step(self.harness, ["--coordinator-cpu", f"--build-at={sha}", "--native-arch"],
                                "artifacts/coordinator-cpu", step_class="exclusive", labels=("measure",),
                                display=True, timeout=3600)
        if result.exit_code:
            raise BenchError(f"coordinator-cpu failed on fleet job {result.job_id}: {result.log_path}")
        self.ingest(ctx, result.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text()
        marker = "COORDINATOR-CPU "
        rows = [line.split(marker, 1)[1] for line in text.splitlines() if marker in line]
        data = json.loads(rows[-1] if rows else text)
        if ctx.build.get("sha") and ctx.build["sha"] != data["app_sha"]:
            raise BenchError(f"expected {ctx.build['sha']}, measured {data['app_sha']}")
        ctx.host.update({"role": "fleet", "name": data["machine"]})
        ctx.notes.append(f"app {data['app_sha']}, harness {data['harness_sha']}, {data['history_rows']} history rows")
        ctx.row("live_renderer_cpu", data["coordinator_live"]["percent"], "%")


BENCH = CoordinatorCPU()
