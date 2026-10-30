set +e
T=/srv/team/t/acme
groupadd -f n-acme-r; groupadd -f n-acme-w; groupadd -f n-acme-a; groupadd -f n-acme.web-w
id austin >/dev/null 2>&1 || useradd -m -G n-acme-r,n-acme.web-w austin
id aziz >/dev/null 2>&1 || useradd -m -G n-acme-r aziz
id lawrence >/dev/null 2>&1 || useradd -m -G n-acme-a,n-acme-r,n-acme-w,n-acme.web-w lawrence
mkdir -p $T/p/web
chgrp n-acme-r $T; chmod 2770 $T $T/p $T/p/web
setfacl -m g:n-acme-r:r-x,g:n-acme-w:rwx,g:n-acme-a:rwx,m:rwx $T && setfacl -d -m g:n-acme-r:r-x,g:n-acme-w:rwx,g:n-acme-a:rwx,m:rwx $T && echo "acl set on node: ok"
setfacl -m g:n-acme-r:r-x,g:n-acme.web-w:rwx,m:rwx $T/p $T/p/web; setfacl -d -m g:n-acme-r:r-x,g:n-acme.web-w:rwx,m:rwx $T/p/web
getfacl -p $T/p/web | grep -c group: | sed 's/^/acl entries web: /'
runuser -u austin -- sh -c "umask 007; echo a > $T/p/web/austin.txt" && echo "austin write web: ok" || echo "austin write web: DENIED"
runuser -u aziz -- sh -c "cat $T/p/web/austin.txt" >/dev/null && echo "aziz read web: ok" || echo "aziz read web: DENIED"
runuser -u aziz -- sh -c "echo z > $T/p/web/aziz.txt" 2>/dev/null && echo "aziz write web: ALLOWED (bad)" || echo "aziz write web: denied (expected)"
getfacl -p $T/p/web/austin.txt | grep -E '^(group|mask)' | tr '\n' ' '; echo
stat -c 'inherit group=%G mode=%a' $T/p/web/austin.txt
runuser -u austin -- mkdir $T/p/web/sub && stat -c 'subdir setgid mode=%a group=%G' $T/p/web/sub && getfacl -p $T/p/web/sub | grep -c default: | sed 's/^/default acl inherited entries: /'
# mailbox modes
mkdir -p /srv/team/mailbox/inbox/lawrence && chmod 1733 /srv/team/mailbox/inbox/lawrence && chown lawrence /srv/team/mailbox/inbox/lawrence
runuser -u austin -- sh -c 'echo m > /srv/team/mailbox/inbox/lawrence/m1.md' && echo "sticky 1733 drop: ok"
runuser -u aziz -- ls /srv/team/mailbox/inbox/lawrence >/dev/null 2>&1 && echo "aziz list inbox: ALLOWED (bad)" || echo "aziz list inbox: denied (expected)"
# inotify on the mount
( inotifywait -q -t 10 -e close_write,moved_to /srv/team/mailbox/inbox/lawrence > /tmp/ino.out ) & sleep 1
runuser -u austin -- sh -c 'echo n > /srv/team/mailbox/inbox/lawrence/.tmp && mv /srv/team/mailbox/inbox/lawrence/.tmp /srv/team/mailbox/inbox/lawrence/m2.md'; wait; echo "inotify: $(cat /tmp/ino.out)"
# flock and rename
flock -n /srv/team/lockfile -c 'flock -n /srv/team/lockfile true && echo "flock: NOT exclusive" || echo "flock: exclusive ok"'
echo x > /srv/team/r1 && mv /srv/team/r1 /srv/team/r2 && test -f /srv/team/r2 && echo "rename: ok"
# xattr
setfattr -n user.k -v v /srv/team/r2 && getfattr -n user.k --only-values /srv/team/r2 && echo " xattr ok"
