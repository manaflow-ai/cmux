#include <pthread.h>
static void*t(void*a){volatile unsigned long x=0;for(;;)x++;}
int main(){pthread_t th;for(int i=0;i<3;i++)pthread_create(&th,0,t,0);t(0);}
