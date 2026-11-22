# Linux 64-bit guests: resume from an opaque filesystem cookie, not an O(n) rescan.
import base64,ctypes,json,os,stat,sys
class Entry(ctypes.Structure):
 _fields_=[("ino",ctypes.c_ulong),("off",ctypes.c_long),("reclen",ctypes.c_ushort),("type",ctypes.c_ubyte),("name",ctypes.c_char*256)]
lib=ctypes.CDLL(None,use_errno=True)
lib.opendir.argtypes=[ctypes.c_char_p];lib.opendir.restype=ctypes.c_void_p
lib.closedir.argtypes=[ctypes.c_void_p]
lib.readdir.argtypes=[ctypes.c_void_p];lib.readdir.restype=ctypes.POINTER(Entry)
lib.telldir.argtypes=[ctypes.c_void_p];lib.telldir.restype=ctypes.c_long
lib.seekdir.argtypes=[ctypes.c_void_p,ctypes.c_long]
lib.dirfd.argtypes=[ctypes.c_void_p];lib.dirfd.restype=ctypes.c_int
p=sys.argv[2]
d=lib.opendir(os.fsencode(p))
if not d:
 err=ctypes.get_errno();raise OSError(err,os.strerror(err),p)
def identity():
 s=os.fstat(lib.dirfd(d));return [s.st_dev,s.st_ino,s.st_mtime_ns,s.st_ctime_ns]
try:
 version=identity();resume=len(sys.argv)>3 and bool(sys.argv[3])
 if resume:
  try:
   cursor=json.loads(base64.b64decode(sys.argv[3],validate=True))
   if not isinstance(cursor,list) or len(cursor)!=5 or any(type(x)!=int for x in cursor):raise ValueError()
   if not 0<=cursor[4]<(1<<64):raise ValueError()
  except Exception:sys.exit(%DIR_CURSOR%)
  if cursor[:4]!=version:sys.exit(%DIR_CHANGED%)
  lib.seekdir(d,ctypes.c_long(cursor[4]))
 entries=[];size=0;next_cursor=None
 while True:
  cookie=lib.telldir(d)&((1<<64)-1)
  ctypes.set_errno(0);entry=lib.readdir(d)
  if not entry:
   err=ctypes.get_errno()
   if err:raise OSError(err,os.strerror(err))
   break
  name=entry.contents.name
  if name in (b".",b".."):continue
  try:s=os.stat(name,dir_fd=lib.dirfd(d),follow_symlinks=False)
  except FileNotFoundError:continue
  kind="directory" if stat.S_ISDIR(s.st_mode) else "symlink" if stat.S_ISLNK(s.st_mode) else "file"
  item={"name":os.fsdecode(name),"kind":kind,"size":s.st_size,"mode":stat.S_IMODE(s.st_mode),"modifiedAt":int(s.st_mtime*1000)}
  encoded=json.dumps(item,ensure_ascii=True,separators=(",",":"))
  if entries and (len(entries)>=%DN% or size+len(encoded)+1>%DB%):
   next_cursor=base64.b64encode(json.dumps(version+[cookie]).encode()).decode();break
  entries.append(encoded);size+=len(encoded)+1
 # Preserve the old one-page scan semantics; multi-page listings require stable positions.
 if (resume or next_cursor is not None) and identity()!=version:sys.exit(%DIR_CHANGED%)
 sys.stdout.write('{"entries":['+','.join(entries)+'],"nextCursor":'+json.dumps(next_cursor)+'}')
finally:lib.closedir(d)
