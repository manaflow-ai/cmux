import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('upgrade', Path(__file__).resolve().parents[1] / 'azure' / 'upgrade.py')
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


def node(name, region):
    return {'group': 'group-' + region, 'node': name, 'region': region,
            'installation': 'CMUX_V3_OK'}


class UpgradeTests(unittest.TestCase):
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
