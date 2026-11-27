"""post the look's gallery read is advisory: it must not sleep out a spent GitHub API hour."""
import pathlib, re, unittest

WF = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-hot-verify.yml"


def step(name):
    text = WF.read_text()
    m = re.search(r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - name: )", text, re.S | re.M)
    assert m, name
    return m.group(1)


class GalleryReadCapped(unittest.TestCase):
    def test_capped(self):
        s = step("Is the gallery advisory also on this head")
        self.assertRegex(s, r"timeout-minutes: [1-5]\n")
        self.assertIn("continue-on-error: true", s)
        m = re.search(r"GH_BUDGET_WAIT_MAX_SECONDS: '?\"?(\d+)", s)
        self.assertTrue(m and int(m.group(1)) <= 120)
        self.assertIn('echo "gallery=false"', s)


if __name__ == "__main__":
    unittest.main()
