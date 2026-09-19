#!/usr/bin/env bash
reload_incremental_digest() { python3 - "$@" <<'PY'
import hashlib, os, stat, sys
h=hashlib.sha256()
for root in sys.argv[1:]:
 root=os.path.abspath(root)
 if not os.path.lexists(root): h.update(b'MISSING'+root.encode()); continue
 paths=[root]
 if os.path.isdir(root) and not os.path.islink(root):
  for base,dirs,files in os.walk(root):
   dirs[:]=sorted(d for d in dirs if d not in {'.git','zig-out','zig-cache'})
   paths += [os.path.join(base,n) for n in sorted(files)+sorted(dirs)]
 for p in sorted(set(paths)):
  st=os.lstat(p); h.update(os.path.relpath(p,root).encode()+bytes([st.st_mode&255]))
  if stat.S_ISLNK(st.st_mode): h.update(os.readlink(p).encode())
  elif stat.S_ISREG(st.st_mode):
   with open(p,'rb') as f:
    while c:=f.read(1048576): h.update(c)
print(h.hexdigest())
PY
}
reload_incremental_output_digest() { [[ -f "$1" ]] && (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | awk '{print $1}' || reload_incremental_digest "$1"; }
reload_incremental_needs_update() { local r="$1" i="$2" o="$3" a b; [[ -e "$o" && -f "$r" ]] || return 0; read -r a b < "$r" || return 0; [[ "$a" == "$i" && "$b" == "$(reload_incremental_output_digest "$o")" ]] || return 0; return 1; }
reload_incremental_record() { local r="$1" i="$2" o="$3"; mkdir -p "$(dirname "$r")"; printf '%s %s\n' "$i" "$(reload_incremental_output_digest "$o")" > "$r.tmp.$$"; mv -f "$r.tmp.$$" "$r"; }
