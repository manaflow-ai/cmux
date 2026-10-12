title: Terminal secrets no longer stay on disk
category: security
try-it: close a terminal tab, then reopen it with closed.reopen

Reopened terminal tabs keep their folder and allowed environment, and cmux no longer keeps environment values such as tokens or passwords in its saved request history. A downgraded daemon cannot match a redacted fingerprint on retry.
