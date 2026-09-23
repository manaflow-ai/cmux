import os,pty,tempfile,select,time,signal
from pathlib import Path
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='cmux13766-') as d:
 p=Path(d); (p/'global').write_text('echo OTHER_TERMINAL\n')
 (p/'.zshrc').write_text('HISTFILE='+str(p/'global')+'\nHISTSIZE=2000\nSAVEHIST=2000\nPS1="PROBE> "\nsource '+str(root/'Resources/shell-integration/cmux-zsh-integration.zsh')+'\n')
 def run(name,commands):
  pid,fd=pty.fork()
  if pid==0:
   os.environ.update(ZDOTDIR=d,CMUX_HISTORY_FILE=str(p/name),CMUX_SOCKET_PATH='',CMUX_SHELL_INTEGRATION='1')
   os.execv('/bin/zsh',['zsh','-i'])
  def prompt():
   out=b''; deadline=time.monotonic()+15
   while time.monotonic()<deadline:
    if select.select([fd],[],[],.5)[0]:
     try:out+=os.read(fd,65536)
     except OSError:break
     if b'PROBE> ' in out: return out
   raise RuntimeError(repr(out))
  try:
   prompt();result=[]
   for cmd in commands:
    os.write(fd,cmd);result.append(prompt())
   return result
  finally:
   os.kill(pid,signal.SIGKILL);os.waitpid(pid,0);os.close(fd)
 print('A',run('a',[b'echo ALPHA_13766\n']))
 print('B',run('b',[b'echo BRAVO_13766\n']))
 a=run('a',[b'\x1b[A\n']);b=run('b',[b'\x1b[A\n'])
 print('RESTORED A',a);print('RESTORED B',b)
 assert b'ALPHA_13766' in a[0] and b'BRAVO_13766' not in a[0]
 assert b'BRAVO_13766' in b[0] and b'ALPHA_13766' not in b[0]
 print('PASS: arrow recall remains isolated after shell restart')
