#ifndef CMUX_CORE_H
#define CMUX_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Call once on the process's main thread, before GUI or worker startup.
int cmux_cli_main(void);

#ifdef __cplusplus
}
#endif
#endif
