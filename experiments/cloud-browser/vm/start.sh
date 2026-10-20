#!/bin/bash
# Starts Xvfb, Chrome (kiosk, one page) and the cmux-rd host on this VM.
# Usage: start.sh [URL] [WxH]   The host listens on 127.0.0.1:4103 (reach it through an SSH -L tunnel).
# The session token goes to ~/rd.token (0600); the viewer reads it from a copy.
set -u
URL=${1:-file://$HOME/marker.html}
SIZE=${2:-1920x1080}
pkill -x Xvfb; pkill -f 'cmux-rd host'; pkill -f chrome; sleep 1
Xvfb :99 -screen 0 ${SIZE}x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
sleep 1
export DISPLAY=:99
google-chrome --user-data-dir=/tmp/cb-profile --no-first-run --no-default-browser-check \
  --password-store=basic --force-device-scale-factor=1 --kiosk \
  --window-position=0,0 --window-size=${SIZE/x/,} --disable-features=Translate \
  "$URL" >/tmp/chrome.log 2>&1 &
sleep 4
xdotool mousemove 960 600 2>/dev/null
umask 077
[ -s ~/rd.token ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > ~/rd.token
setsid nohup cmux-rd host --owner owner --display :99 --port 4103 --codec x264 --max-fps 60 ${HOSTARGS:-} \
  --token-fd 3 3< <(cat ~/rd.token) >/tmp/host.log 2>&1 &
sleep 1
pgrep -a cmux-rd; tail -3 /tmp/host.log
