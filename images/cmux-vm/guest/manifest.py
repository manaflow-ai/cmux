#!/usr/bin/env python3
# File-hash manifest of the baked image (images/cmux-vm/bake.ts).
# One line per entry: path, F|L, sha256 or symlink target, size, mode.
# Roots are the trees the bake writes; the reproducibility check diffs two bakes' manifests.
import hashlib, os, stat, sys

ROOTS = ["/usr/local", "/opt", "/etc/cmux", "/etc/systemd/system", "/etc/apt", "/etc/profile.d", "/usr/lib/postgresql", "/home/cmux"]
SKIP = ("/opt/freestyle/",)

def main(out_path: str) -> None:
    count = 0
    with open(out_path, "w") as out:
        for root in ROOTS:
            if not os.path.exists(root):
                continue
            for dirpath, dirs, files in os.walk(root):
                dirs.sort()
                if dirpath.startswith(SKIP) or dirpath + "/" in SKIP:
                    dirs[:] = []
                    continue
                for name in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
                    p = os.path.join(dirpath, name)
                    try:
                        st = os.lstat(p)
                    except OSError:
                        continue
                    if stat.S_ISLNK(st.st_mode):
                        out.write(f"{p}\tL\t{os.readlink(p)}\t{st.st_size}\n")
                    elif stat.S_ISREG(st.st_mode):
                        h = hashlib.sha256()
                        with open(p, "rb") as f:
                            for chunk in iter(lambda: f.read(1 << 20), b""):
                                h.update(chunk)
                        out.write(f"{p}\tF\t{h.hexdigest()}\t{st.st_size}\t{oct(st.st_mode & 0o7777)}\n")
                    else:
                        continue
                    count += 1
    print("manifest-entries", count)

if __name__ == "__main__":
    main(sys.argv[1])
