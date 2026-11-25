import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from benches.download_bridge import BENCH  # noqa: E402
from benchlib.bench import Context  # noqa: E402

LOG = 'x\ndownload-bridge: {"os": "Linux", "seconds": 36.5, "warmSeconds": 25.4, "downloadBytes": 523481453, ' \
      '"nodeModulesBytes": 623632760, "lazyReadBytes": 54277762}\n'


class DownloadBridgeTest(unittest.TestCase):
    def test_ingest_rows(self) -> None:
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "0" * 40}, host_role="anywhere")
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log"
            p.write_text(LOG, encoding="utf-8")
            BENCH.ingest(ctx, p)
        got = {r["metric"]: r["value"] for r in ctx.rows}
        self.assertEqual(got["download_bytes"], 523481453)
        self.assertEqual(got["install_s"], 36.5)
        self.assertEqual(len(ctx.rows), 5)


if __name__ == "__main__":
    unittest.main()
