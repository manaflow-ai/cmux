# 2026-11-26-publish-nightly-reel-1

Above `permissions:` (job `publish-nightly-reel`) in `.github/workflows/nightly.yml`.

contents: write reaches the pr-media branch only through
.github/actions/pr-media-publish: its privacy check (pr_media_privacy.py,
with tesseract OCR for the reel's frames) refuses any private name in this
bot's folder before the first upload.
