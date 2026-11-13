import importlib.util
import json
import subprocess
import sys
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
            self.assertEqual(bundle["modules"][0]["attributionMetric"], "emitted")
            self.assertEqual(bundle["modules"][0]["emittedBytes"], 1_000)

    def test_rolldown_rendered_bytes_are_separate_from_emitted_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "rolldown.json"
            metafile.write_text(json.dumps({
                "schema": 2,
                "tool": "rolldown",
                "outputs": {"entry.js": {"bytes": 600, "inputs": {
                    "src/module.ts": {
                        "sourceBytes": 2_000,
                        "renderedBytes": 1_000,
                        "bytesInOutput": 1_000,
                        "metric": "rolldown-rendered-pre-minification",
                    }
                }}},
            }), encoding="utf-8")
            bundle = MODULE.load_bundle("rolldown", metafile, None)
            row = bundle["modules"][0]
            self.assertEqual(bundle["shippedBytes"], 0)
            self.assertEqual(bundle["reachableBytes"], 1_000)
            self.assertEqual(bundle["attributionMetric"], "rolldown-rendered-pre-minification")
            self.assertEqual(row["renderedBytes"], 1_000)
            self.assertEqual(row["emittedBytes"], 0)
            self.assertEqual(bundle["outputs"][0]["bytes"], 600)

    def test_legacy_rolldown_bytes_are_unknown_not_emitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = root / "legacy-rolldown.json"
            metafile.write_text(json.dumps({
                "schema": 1,
                "tool": "rolldown",
                "outputs": {"entry.js": {"bytes": 600, "inputs": {
                    "src/module.ts": {"bytes": 2_000, "bytesInOutput": 1_000}
                }}},
            }), encoding="utf-8")
            bundle = MODULE.load_bundle("legacy", metafile, None)
            row = bundle["modules"][0]
            self.assertIsNone(bundle["reachableBytes"])
            self.assertEqual(bundle["attributionMetric"], "unknown")
            self.assertEqual(row["unknownBytes"], 1_000)
            self.assertEqual(row["emittedBytes"], 0)

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

    def test_duplicate_react_detector_reports_real_multiple_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pages = self.write_bundle(root, "pages", [("one/node_modules/react/index.js", 100, 80)])
            pane = self.write_bundle(root, "pane", [("two/node_modules/react/index.js", 100, 80)])
            output = root / "report.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), "--metafile", f"pages={pages}",
                 "--metafile", f"pane={pane}", "--json", str(output)],
                check=True, capture_output=True, text=True,
            )
            report = json.loads(output.read_text())
            self.assertEqual(len(report["duplicates"]["react"]["instances"]), 2)
            self.assertTrue(any("duplicate react package across bundles" in finding for finding in report["findings"]))

    def test_installed_copies_use_canonical_paths_across_bundlers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_root = root / "checkout/webviews"
            source_root.mkdir(parents=True)
            module = "node_modules/prosemirror-model/dist/index.js"
            absolute = self.write_bundle(source_root, "absolute", [(module, 100, 80)])
            relative = root / "relative.json"
            relative.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 80, "inputs": {module: {"bytesInOutput": 80}}}}}), encoding="utf-8")
            output = root / "report.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), "--metafile", f"pages={relative}",
                 "--metafile", f"webviews={absolute}", "--source-root", f"pages={source_root}",
                 "--json", str(output)],
                check=True, capture_output=True, text=True,
            )
            package = json.loads(output.read_text())["duplicates"]["prosemirror-model"]
            self.assertEqual(package["bundles"], ["pages", "webviews"])
            self.assertEqual(len(package["instances"]), 1)
            self.assertEqual(package["instances"][0], str(source_root / "node_modules/prosemirror-model"))

    def test_nested_installed_copy_remains_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metafile = self.write_bundle(root, "one", [
                ("node_modules/react/index.js", 100, 80),
                ("node_modules/widget/node_modules/react/index.js", 100, 80),
            ])
            bundle = MODULE.load_bundle("one", metafile, root)
            self.assertEqual(len({row["packageInstance"] for row in bundle["modules"]}), 2)

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

    def test_barrel_comments_do_not_count_as_exports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.ts"
            source.write_text("// export * from './missing';\nconst text = \"export * from './missing'\";\n", encoding="utf-8")
            metafile = root / "bundle.json"
            metafile.write_text(json.dumps({"outputs": {"entry.js": {"bytes": 10, "inputs": {"source.ts": {"bytesInOutput": 10}}}}}), encoding="utf-8")
            bundle = MODULE.load_bundle("bundle", metafile, root)
            self.assertEqual(bundle["barrels"], [])


if __name__ == "__main__":
    unittest.main()
