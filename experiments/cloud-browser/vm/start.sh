#!/bin/bash
# Starts Xvfb and the cmux-rd host with its cloud browser (Chrome, kiosk, one page) on this VM.
# Usage: start.sh [URL] [WxH]   The host listens on 127.0.0.1:4103 (reach it through an SSH -L tunnel).
# HOSTARGS adds host flags: --profile baseline for the openh264 bench decoder;
# --browser-bin ~/chrome-nosmooth (a wrapper adding --disable-smooth-scrolling) as measured in the design doc.
# The session token goes to ~/rd.token (0600); the viewer reads it from a copy.
set -u
URL=${1:-file://$HOME/marker.html}
SIZE=${2:-1920x1080}
pkill -x Xvfb; pkill -x cmux-rd; pkill -x chrome; sleep 1
Xvfb :99 -screen 0 ${SIZE}x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
sleep 1
DISPLAY=:99 xdotool mousemove $(( ${SIZE%x*} / 2 )) $(( ${SIZE#*x} / 2 )) 2>/dev/null
umask 077
[ -s ~/rd.token ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > ~/rd.token
setsid nohup cmux-rd host --browser "$URL" --owner owner --display :99 --port 4103 --codec x264 --max-fps 60 ${HOSTARGS:-} \
  --token-fd 3 3< <(cat ~/rd.token) >/tmp/host.log 2>&1 &
sleep 4
pgrep -a cmux-rd; tail -3 /tmp/host.log
