set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq fuse3 acl auditd ripgrep git sqlite3 postgresql-client attr inotify-tools >/dev/null
grep -q '^user_allow_other' /etc/fuse.conf || echo user_allow_other >> /etc/fuse.conf
cd /tmp && V=1.4.1
curl -fsSLO https://github.com/juicedata/juicefs/releases/download/v$V/juicefs-$V-linux-amd64.tar.gz
curl -fsSLO https://github.com/juicedata/juicefs/releases/download/v$V/checksums.txt
grep " juicefs-$V-linux-amd64.tar.gz" checksums.txt | sha256sum -c -
tar xzf juicefs-$V-linux-amd64.tar.gz juicefs && install -m 755 juicefs /usr/local/bin/juicefs
juicefs version; ls -la /dev/fuse; uname -r; nproc; free -m | sed -n 2p
juicefs format --help | grep -E 'session-token|enable-acl|trash-days' 
