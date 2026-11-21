import importlib.util
import json
from pathlib import Path

SCRIPT = Path(__file__).parents[2] / "scripts/cmux-next-stress-bench/report.py"
spec = importlib.util.spec_from_file_location("stress_report", SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def test_build_rows_marks_lower_is_better_regression(tmp_path):
    result = {"scenario": "chats", "metrics": {"frame_rate": 45, "input_to_paint_ms": {"p95": 30}, "cpu_pct": 12}, "recovered": True}
    rows = report.build_rows([(Path("chats.json"), result)], {("chats", "frame_rate"): 60, ("chats", "input_to_paint_ms.p95"): 10}, 10)
    assert {row.metric for row in rows if row.status == "regression"} == {"frame_rate", "input_to_paint_ms.p95"}


def test_cli_limits_issue_queue_to_top_five(tmp_path):
    results = tmp_path / "results"
    results.mkdir()
    for index in range(7):
        (results / f"s{index}.json").write_text(json.dumps({"scenario": f"s{index}", "metrics": {"frame_rate": 10 + index}}))
    baseline = tmp_path / "baseline.json"
    baseline.write_text(json.dumps({"rows": [{"scenario": f"s{index}", "metric": "frame_rate", "value": 100} for index in range(7)]}))
    output, markdown, issues = (tmp_path / name for name in ("report.json", "report.md", "issues.json"))
    assert report.main(["--results-dir", str(results), "--baseline", str(baseline), "--output-json", str(output), "--output-markdown", str(markdown), "--issue-output", str(issues)]) == 0
    data = json.loads(output.read_text())
    assert data["issue_count"] == 5
    assert len(json.loads(issues.read_text())) == 5
    assert "| Scenario | Metric |" in markdown.read_text()
