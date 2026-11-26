# publish-nightly-reel: permissions:

Where: the `publish-nightly-reel` job in `.github/workflows/nightly.yml`, above `permissions:`.

contents: write reaches the pr-media branch only through
.github/actions/pr-media-publish: its privacy check (pr_media_privacy.py,
with tesseract OCR for the reel's frames) refuses any private name in this
bot's folder before the first upload.
