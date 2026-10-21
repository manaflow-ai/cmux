set -u
cd /work
[ -x /opt/cmux-screen-host ] || { bash /work/build.sh >/tmp/b2.log 2>&1; cp /work/cmux-screen/target/release/cmux-screen-host /opt/; }; ls -l /opt/cmux-screen-host || exit 1
command -v google-chrome >/dev/null || { curl -sSfLo /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/chrome.deb >/dev/null 2>&1; }; google-chrome --version
pkill -x Xvfb; pkill -f cmux-screen-host; pkill -f chrome; sleep 1
Xvfb :1 -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 & sleep 1
measure() { # $1 page  $2 label
  pkill -f 'user-data-dir=/tmp/cb-page'; pkill -f cmux-screen-host; sleep 1
  DISPLAY=:1 google-chrome --no-sandbox --user-data-dir=/tmp/cb-page --no-first-run --password-store=basic --force-device-scale-factor=1 --kiosk --window-position=0,0 --window-size=1920,1080 "file:///work/$1" >/tmp/page.log 2>&1 &
  sleep 4
  rm -rf ~/.config/cmux-vnc-host
  DISPLAY=:1 /opt/cmux-screen-host --backend desktop --no-tailnet --name cloud-browser-check >/tmp/host-$2.log 2>&1 &
  for i in $(seq 1 30); do [ -s ~/.config/cmux-vnc-host/pairing.json ] && break; sleep 0.5; done
  P=~/.config/cmux-vnc-host/pairing.json
  sig=$(jq -r .signal $P); room=$(jq -r .room $P); sec=$(jq -r .secret $P)
  sleep 3
  url="file:///work/viewer.html?signal=$(jq -rn --arg s "$sig" '$s|@uri')&room=$room&secret=$(jq -rn --arg s "$sec" '$s|@uri')&seconds=20"
  rm -rf /tmp/cb-viewer
  google-chrome --no-sandbox --headless=new --user-data-dir=/tmp/cb-viewer --remote-debugging-port=9333 --autoplay-policy=no-user-gesture-required "$url" >/tmp/viewer.log 2>&1 &
  res=""
  for i in $(seq 1 90); do sleep 1; res=$(curl -s 127.0.0.1:9333/json/list | jq -r '.[] | select(.type=="page") | .title' | grep '^RESULT:' | head -1); [ -n "$res" ] && break; done
  echo "$2 ${res#RESULT:}"; [ -n "$res" ] || { curl -s 127.0.0.1:9333/json/list | jq -r ".[].title"; tail -5 /tmp/viewer.log; tail -8 /tmp/host-$2.log; }
  echo "host cpu: $(ps -o %cpu= -C cmux-screen-host | head -1)"
  pkill -f 'user-data-dir=/tmp/cb-viewer'
  grep -iE 'error|refused|could not' /tmp/host-$2.log | head -3
}
measure motion.html motion
measure motion.html motion-2
tail -3 /tmp/host-motion.log
