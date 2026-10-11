#!/bin/sh
# Program status protocol (OSC 7501) demo: run it in a cmux terminal and read
# the records with `cmux terminal current status` from another terminal.
# Spec: https://mitchellh.com/writing/program-status-osc7501
set -eu

status() { printf '\033]7501;%s\033\\' "$1"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

status 'state=working:progress=40'
sleep "${STEP:-2}"
status "state=blocked:kind=permission:app=demo:msg=$(b64 'Apply the plan?')"
sleep "${STEP:-2}"
status 'state=working:id=build:progress=80'
status "state=done:app=demo:msg=$(b64 'Plan applied')"
sleep "${STEP:-2}"
status 'state=clear:id=build'
