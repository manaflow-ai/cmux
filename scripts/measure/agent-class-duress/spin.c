// One busy thread at the default priority: another app's load, not an agent's.
int main(void) { volatile unsigned long x = 0; for (;;) x++; }
