#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
int main(int c, char**v){ for(int i=1;i<c;i++){ mach_port_t t; kern_return_t k=task_for_pid(mach_task_self(), atoi(v[i]), &t);
 printf("task_for_pid(%s) = %d (%s)\n", v[i], k, k==KERN_SUCCESS?"OK: can inject":mach_error_string(k)); } }
