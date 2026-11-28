# nightly.yml: job `publish-nightly-reel`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

contents: write reaches the pr-media branch only through
.github/actions/pr-media-publish: its privacy check (pr_media_privacy.py,
with tesseract OCR for the reel's frames) refuses any private name in this
bot's folder before the first upload.
