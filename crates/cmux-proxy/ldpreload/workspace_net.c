// LD_PRELOAD shim to reroute bind/connect to a per-workspace loopback IP
// Mapping: workspace-N -> 127.18.(N>>8).(N&255)
// Detection:
//  - If CMUX_WORKSPACE_INTERNAL is set, use that workspace name
//  - Else, if CWD is under /root/workspace-*, use that directory name
// Disable via CMUX_PRELOAD_DISABLE=1

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

static int (*real_bind)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*real_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*real_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **) = NULL;

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static bool active = false;
static uint32_t ws_ip_be = 0; // workspace IP in network byte order

static void log_msg(const char *msg) {
    const char *v = getenv("CMUX_PRELOAD_LOG");
    if (v && *v) {
        fprintf(stderr, "[cmux-preload] %s\n", msg);
    }
}

static const char *last_path_component(const char *path) {
    if (!path) return NULL;
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int parse_trailing_number(const char *s, uint32_t *out) {
    if (!s || !*s) return -1;
    // find end
    size_t len = strlen(s);
    // walk backwards to find first non-digit
    size_t i = len;
    while (i > 0 && s[i-1] >= '0' && s[i-1] <= '9') { i--; }
    if (i == len) return -1; // no digits
    const char *digits = s + i;
    char *end = NULL;
    unsigned long v = strtoul(digits, &end, 10);
    if (!end || *end != '\0') return -1;
    if (v > 0xFFFFFFFFul) return -1;
    *out = (uint32_t)v;
    return 0;
}

static uint32_t ip_for_workspace_num_be(uint32_t n) {
    uint8_t b2 = (uint8_t)((n >> 8) & 0xFF);
    uint8_t b3 = (uint8_t)(n & 0xFF);
    uint32_t ip = (127u << 24) | (18u << 16) | ((uint32_t)b2 << 8) | (uint32_t)b3;
    return htonl(ip);
}

static uint32_t fnv1a16_lower(const char *s) {
    uint32_t h = 0x811C9DC5u; // FNV-1a 32-bit offset
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c - 'A' + 'a');
        h ^= (uint32_t)c;
        h *= 0x01000193u; // FNV prime
    }
    return h & 0xFFFFu;
}

static void init_real_fns(void) {
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_connect = dlsym(RTLD_NEXT, "connect");
    real_getaddrinfo = dlsym(RTLD_NEXT, "getaddrinfo");
}

static void detect_workspace(void) {
    const char *disable = getenv("CMUX_PRELOAD_DISABLE");
    if (disable && *disable == '1') {
        active = false;
        log_msg("disabled via CMUX_PRELOAD_DISABLE");
        return;
    }

    uint32_t n = 0;
    const char *ws_env = getenv("CMUX_WORKSPACE_INTERNAL");
    if (ws_env && *ws_env) {
        const char *base = last_path_component(ws_env);
        if (parse_trailing_number(base, &n) != 0) { n = fnv1a16_lower(base); }
        ws_ip_be = ip_for_workspace_num_be(n);
        active = true;
        log_msg("workspace detected via CMUX_WORKSPACE_INTERNAL");
        return;
    }

    char cwd[4096];
    if (getcwd(cwd, sizeof(cwd)) != NULL) {
        // Expect paths like /root/workspace-1 or any /root/*
        const char *base = last_path_component(cwd);
        if (base && strncmp(base, "workspace-", 10) == 0) {
            if (parse_trailing_number(base, &n) != 0) { n = fnv1a16_lower(base); }
            ws_ip_be = ip_for_workspace_num_be(n);
            active = true;
            log_msg("workspace detected via CWD");
            return;
        }
    }

    active = false;
}

static void init_all(void) {
    init_real_fns();
    detect_workspace();
}

static inline bool is_loopback_localhost_be(uint32_t be) {
    // 127.0.0.1
    static uint32_t lo_be = 0;
    if (!lo_be) lo_be = inet_addr("127.0.0.1");
    return be == lo_be;
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    pthread_once(&init_once, init_all);
    if (!real_bind) { errno = EINVAL; return -1; }
    if (!active || !addr || addr->sa_family != AF_INET) {
        return real_bind(sockfd, addr, addrlen);
    }

    struct sockaddr_in tmp;
    if (addrlen < (socklen_t)sizeof(tmp)) return real_bind(sockfd, addr, addrlen);
    memcpy(&tmp, addr, sizeof(tmp));

    if (tmp.sin_addr.s_addr == INADDR_ANY || is_loopback_localhost_be(tmp.sin_addr.s_addr)) {
        tmp.sin_addr.s_addr = ws_ip_be;
    }
    return real_bind(sockfd, (const struct sockaddr *)&tmp, sizeof(tmp));
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    pthread_once(&init_once, init_all);
    if (!real_connect) { errno = EINVAL; return -1; }
    if (!active || !addr || addr->sa_family != AF_INET) {
        return real_connect(sockfd, addr, addrlen);
    }
    struct sockaddr_in tmp;
    if (addrlen < (socklen_t)sizeof(tmp)) return real_connect(sockfd, addr, addrlen);
    memcpy(&tmp, addr, sizeof(tmp));
    if (is_loopback_localhost_be(tmp.sin_addr.s_addr)) {
        tmp.sin_addr.s_addr = ws_ip_be;
    }
    return real_connect(sockfd, (const struct sockaddr *)&tmp, sizeof(tmp));
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    pthread_once(&init_once, init_all);
    if (!real_getaddrinfo) {
        init_real_fns();
        if (!real_getaddrinfo) return EAI_SYSTEM;
    }

    if (!active || !node) {
        return real_getaddrinfo(node, service, hints, res);
    }

    // If node refers to localhost (or blank which some apps treat as localhost), return workspace IP first
    bool is_localhost = false;
    if (node == NULL || *node == '\0') {
        is_localhost = true;
    } else if (strcmp(node, "localhost") == 0 || strcmp(node, "127.0.0.1") == 0) {
        is_localhost = true;
    }

    if (!is_localhost) {
        return real_getaddrinfo(node, service, hints, res);
    }

    // Build a minimal addrinfo result with our IPv4 address
    struct addrinfo *ai = calloc(1, sizeof(struct addrinfo));
    if (!ai) return EAI_MEMORY;
    struct sockaddr_in *sa = calloc(1, sizeof(struct sockaddr_in));
    if (!sa) { free(ai); return EAI_MEMORY; }
    sa->sin_family = AF_INET;
    sa->sin_addr.s_addr = ws_ip_be;
    if (service) {
        // try numeric port
        char *end = NULL;
        long p = strtol(service, &end, 10);
        if (end && *end == '\0' && p > 0 && p < 65536) {
            sa->sin_port = htons((uint16_t)p);
        }
    }
    ai->ai_family = AF_INET;
    ai->ai_socktype = hints ? hints->ai_socktype : 0;
    ai->ai_protocol = hints ? hints->ai_protocol : 0;
    ai->ai_addrlen = sizeof(struct sockaddr_in);
    ai->ai_addr = (struct sockaddr *)sa;
    ai->ai_next = NULL;
    *res = ai;
    return 0;
}
