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

    def test_relative_inputs_use_metafile_source_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_root = root / "checkout" / "webviews"
            source_root.mkdir(parents=True)
            source = source_root / "src/barrel.ts"
            source.parent.mkdir(parents=True)
            source.write_text("export * from './child';\n", encoding="utf-8")
            metafile = root / "reports/pages.json"
            metafile.parent.mkdir()
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {"src/barrel.ts": {"bytes": 200}},
                        "outputs": {
                            "entry.js": {
                                "bytes": 100,
                                "inputs": {"src/barrel.ts": {"bytesInOutput": 100}},
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("pages", metafile, root, source_root)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)

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
            cjs.write_text("// require('comment')\nconst text = 'require('; module.exports = {};", encoding="utf-8")
            dev.write_text("export const fixture = true;", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 30, "inputs": {str(cjs): {"bytes": 20, "bytesInOutput": 20}, str(dev): {"bytes": 10, "bytesInOutput": 10}}}}}), encoding="utf-8")
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(len(bundle["commonjs"]), 1)
            self.assertEqual(len(bundle["devInputs"]), 1)

    def test_commonjs_metadata_format_is_marked_without_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "bundle.json"
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {"generated.js": {"bytes": 100, "format": "cjs", "imports": []}},
                        "outputs": {"entry.js": {"bytes": 100, "inputs": {"generated.js": {"bytesInOutput": 100}}}},
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(len(bundle["commonjs"]), 1)

    def test_barrel_graph_includes_exported_child_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            barrel = root / "barrel.ts"
            child = root / "child.ts"
            barrel.write_text("export * from './child';\n", encoding="utf-8")
            child.write_text("export const value = 'x'.repeat(100_000);\n", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(
                json.dumps(
                    {
                        "inputs": {
                            "barrel.ts": {"bytes": barrel.stat().st_size},
                            "child.ts": {"bytes": child.stat().st_size},
                        },
                        "outputs": {
                            "entry.js": {
                                "bytes": 100_000,
                                "inputs": {
                                    "barrel.ts": {"bytesInOutput": 0},
                                    "child.ts": {"bytesInOutput": 100_000},
                                },
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(bundle["barrels"][0]["barrel"], 1)
            self.assertEqual(bundle["barrels"][0]["barrelReachableBytes"], 100_000)


if __name__ == "__main__":
    unittest.main()
