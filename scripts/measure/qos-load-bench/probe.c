// Foreground probes for the QoS bench. Two threads, both at the app main thread's QoS
// (user-interactive), default disk I/O policy:
//  frame: every 8.33 ms (120 Hz) wake, do 2 ms of work, record how late the work finished
//         past its deadline (wake + 2 ms) -> "input-to-frame" proxy.
//  disk:  every 50 ms, a 4 KiB uncached read at a random offset of a 512 MiB file plus a
//         4 KiB write + fsync -> main-thread / journal I/O proxy.
// Prints p50/p95/p99/max in microseconds and count of frames late > 16.7 ms ("hangs").
#include <fcntl.h>
#include <stdint.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
// Any probe I/O failure ends the run: a failed call is not a latency sample.
static void must(int ok,const char*what){if(!ok){perror(what);exit(1);}}
static double tb; static double now_us(){return mach_absolute_time()*tb/1000.0;}
static int secs; static const char*dir;
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
static void report(const char*name,double*v,int n,double hang){qsort(v,n,sizeof(double),cmp);int h=0;for(int i=0;i<n;i++)if(v[i]>hang)h++;
 printf("%s n=%d p50=%.0f p95=%.0f p99=%.0f max=%.0f over%.0fms=%d\n",name,n,v[n/2],v[n*95/100],v[n*99/100],v[n-1],hang/1000,h);}
static void spin_us(double us){double e=now_us()+us;volatile int x=0;while(now_us()<e)x++;}
static void*frame(void*a){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);int n=secs*120;double*v=malloc(n*sizeof(double));double*wl=malloc(n*sizeof(double));
 double t0=now_us();for(int i=0;i<n;i++){double due=t0+i*8333.0;double w;while((w=now_us())<due){double d=due-w;if(d>200)usleep((useconds_t)(d-100));}
  double st=now_us();spin_us(2000);double fin=now_us();v[i]=fin-due;wl[i]=st-due;}
 report("frame_due_to_done_us",v,n,16667);report("frame_wake_late_us",wl,n,16667);return 0;}
static void*disk(void*a){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);char p[512];snprintf(p,sizeof p,"%s/probe.dat",dir);
 int fd=open(p,O_RDWR);must(fd>=0,p);fcntl(fd,F_NOCACHE,1);char*buf;posix_memalign((void**)&buf,4096,4096);memset(buf,1,4096);
 char w[512];snprintf(w,sizeof w,"%s/journal.dat",dir);int wfd=open(w,O_RDWR|O_CREAT|O_TRUNC,0600);must(wfd>=0,w);
 int n=secs*20;double*v=malloc(n*sizeof(double));double*fv=malloc(n*sizeof(double));for(int i=0;i<n;i++){double s=now_us();off_t off=((off_t)arc4random_uniform(131072))*4096;must(pread(fd,buf,4096,off)==4096,"pread");
  double m=now_us();v[i]=m-s;must(write(wfd,buf,4096)==4096,"write");must(fsync(wfd)==0,"fsync");fv[i]=now_us()-m;usleep(50000);}
 report("disk_read_us",v,n,16667);report("disk_write_fsync_us",fv,n,16667);return 0;}
// atomic: every 300 ms (the composer's draft throttle) write 64 KiB to a temp file and rename it over
//         the target, as Foundation's Data.write(options: .atomic) does: the main-thread cost of a
//         small state-file save.
static void*atomicw(void*a){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);char t[512],f[512];snprintf(t,sizeof t,"%s/state.tmp",dir);snprintf(f,sizeof f,"%s/state.json",dir);
 char*buf=malloc(65536);memset(buf,'x',65536);int n=secs*10/3;double*v=malloc(n*sizeof(double));
 for(int i=0;i<n;i++){double s=now_us();int fd=open(t,O_WRONLY|O_CREAT|O_TRUNC,0600);must(fd>=0,t);must(write(fd,buf,65536)==65536,"write");must(close(fd)==0,"close");must(rename(t,f)==0,"rename");v[i]=now_us()-s;usleep(300000);}
 report("atomic_write_us",v,n,16667);return 0;}
int main(int c,char**v){mach_timebase_info_data_t i;mach_timebase_info(&i);tb=(double)i.numer/i.denom;if(c<3){fprintf(stderr,"usage: probe SECONDS DIR\n");return 2;}secs=atoi(v[1]);dir=v[2];
 pthread_t a,b,w;pthread_create(&a,0,frame,0);pthread_create(&b,0,disk,0);pthread_create(&w,0,atomicw,0);pthread_join(a,0);pthread_join(b,0);pthread_join(w,0);return 0;}
