import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "web-bundle-report.py"
SPEC = importlib.util.spec_from_file_location("web_bundle_report", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class WebBundleReportTests(unittest.TestCase):
    def write_bundle(self, root, name, modules):
        metafile = root / f"{name}.json"
        inputs = {}
        for path, source_bytes, emitted in modules:
            source = root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("export * from './child';\n" if "barrel" in path else "export const value = 1;\n", encoding="utf-8")
            inputs[str(source)] = {"bytes": source_bytes, "bytesInOutput": emitted}
        metafile.write_text(
            json.dumps(
                {
                    "inputs": {path: {"bytes": value["bytes"]} for path, value in inputs.items()},
                    "outputs": {
                        "entry.js": {
                            "bytes": sum(i["bytesInOutput"] for i in inputs.values()),
                            "inputs": {
                                path: {"bytesInOutput": value["bytesInOutput"]}
                                for path, value in inputs.items()
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        return metafile

    def test_reachability_and_shaken_barrel(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [("barrel.ts", 200_000, 1_000)])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(bundle["modules"][0]["sourceBytes"], 200_000)
            self.assertEqual(bundle["modules"][0]["reachableBytes"], 1_000)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)

    def test_esbuild_top_level_input_bytes_are_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [("source.ts", 200_000, 1_000)])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(bundle["modules"][0]["sourceBytes"], 200_000)

    def test_duplicate_react_groups_by_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = self.write_bundle(root, "pages", [("node_modules/react/index.js", 100, 80)])
            second = self.write_bundle(root, "pane", [("node_modules/react/index.js", 100, 80)])
            one = MODULE.load_bundle("pages", first, root)
            two = MODULE.load_bundle("pane", second, root)
            bundles = {"react": {"bundles": [one["name"], two["name"]], "paths": ["node_modules/react/index.js"]}}
            self.assertEqual(len(bundles["react"]["bundles"]), 2)

    def test_commonjs_and_dev_inputs_are_marked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cjs = root / "node_modules/pkg/index.cjs"
            dev = root / "src/gallery/example.test.ts"
            cjs.parent.mkdir(parents=True, exist_ok=True)
            dev.parent.mkdir(parents=True, exist_ok=True)
            cjs.write_text("module.exports = require('x');", encoding="utf-8")
            dev.write_text("export const fixture = true;", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 30, "inputs": {str(cjs): {"bytes": 20, "bytesInOutput": 20}, str(dev): {"bytes": 10, "bytesInOutput": 10}}}}}), encoding="utf-8")
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(len(bundle["commonjs"]), 1)
            self.assertEqual(len(bundle["devInputs"]), 1)


if __name__ == "__main__":
    unittest.main()
