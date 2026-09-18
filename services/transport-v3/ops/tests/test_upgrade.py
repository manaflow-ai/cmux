import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('upgrade', Path(__file__).resolve().parents[1] / 'azure' / 'upgrade.py')
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)

observe_spec = importlib.util.spec_from_file_location(
    'observe', Path(__file__).resolve().parents[1] / 'azure' / 'observe.py'
)
observe = importlib.util.module_from_spec(observe_spec)
observe_spec.loader.exec_module(observe)
sys.modules['observe'] = observe
alerts_spec = importlib.util.spec_from_file_location(
    'alerts', Path(__file__).resolve().parents[1] / 'azure' / 'alerts.py'
)
alerts = importlib.util.module_from_spec(alerts_spec)
alerts_spec.loader.exec_module(alerts)


def node(name, region):
    return {'group': 'group-' + region, 'node': name, 'region': region,
            'installation': 'CMUX_V3_OK'}


class UpgradeTests(unittest.TestCase):
    def test_alerts_include_no_healthy_generation_guard(self):
        nodes = [{**node('new-east', 'eastus'), 'vm': 'new-east'},
                 {**node('new-west', 'westus2'), 'vm': 'new-west'}]
        query = alerts.queries(nodes)['no-healthy-generation']
        self.assertIn('healthy=countif', query)
        self.assertIn('no_healthy_generation', query)
        self.assertIn('take_any(ResourceId)', query)

    def test_requires_distinct_overlapping_generations(self):
        old = {'image': 'sha256:old', 'nodes': [node('old-east', 'eastus'), node('old-west', 'westus2')]}
        new = {'image': 'sha256:new', 'nodes': [node('new-east', 'eastus'), node('new-west', 'westus2')]}
        upgrade.validate(old, new)
        with self.assertRaisesRegex(ValueError, 'distinct'):
            upgrade.validate(old, {**new, 'image': old['image']})
        with self.assertRaisesRegex(ValueError, 'reuses'):
            upgrade.validate(old, {**new, 'nodes': [old['nodes'][0], new['nodes'][1]]})

    def test_requires_same_region_coverage(self):
        old = {'image': 'sha256:old', 'nodes': [node('old-east', 'eastus'), node('old-west', 'westus2')]}
        new = {'image': 'sha256:new', 'nodes': [node('new-east', 'eastus'), node('new-eu', 'westeurope')]}
        with self.assertRaisesRegex(ValueError, 'regions'):
            upgrade.validate(old, new)


if __name__ == '__main__':
    unittest.main()
