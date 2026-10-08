"""Keep the cmux-next web-bundle cache usable between Linux and macOS jobs."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"


def test_web_bundle_cache_is_cross_os_on_every_reader_and_writer() -> None:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    cache_steps = []
    for job_name, job in workflow["jobs"].items():
        for step in job.get("steps", []):
            if "cmux-next-web-bundles-v1-" not in str(step.get("with", {}).get("key", "")):
                continue
            cache_steps.append((job_name, step))

    assert {job_name for job_name, _ in cache_steps} == {
        "web-bundles",
        "swift-test",
        "daemon-test",
        "generated-files",
    }
    assert len(cache_steps) == 5
    assert all(step["with"].get("enableCrossOsArchive") is True for _, step in cache_steps)

    actions = {step["uses"].split("@", 1)[0] for _, step in cache_steps}
    assert actions == {"actions/cache/restore", "actions/cache/save"}
