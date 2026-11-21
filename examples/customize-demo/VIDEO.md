# The customization demo, recorded

Each look below was recorded in the published cmux NEXT nightly on a fresh home, on a fleet capture
Mac, from the profile files at the commit named in each row. A clip is the window while the look is
applied and a fresh New Tab opens; the screenshot is the same moment held still.

| Look | Clip | Screenshot | Reproduce on your Mac |
| --- | --- | --- | --- |
<!-- rows filled from the capture receipts -->

To show one look in your installed NIGHTLY, run its command, look, then press Enter: the script puts
your own setup back. Run the next look only after that reset completes.

To record them again:

```sh
python3 examples/customize-demo/record-steps.py --ref "$(git rev-parse HEAD)" --video \
  --output-dir /tmp/demo-states
cmux-ci capture --nightly latest --state /tmp/demo-states/looks-claude.json
```

`record-steps.py` writes one state per look (14 steps each, under the runner's 60-step limit); run
each state once and keep its receipt.
