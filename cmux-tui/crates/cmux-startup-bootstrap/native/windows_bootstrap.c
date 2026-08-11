#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <intrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#pragma comment(lib, "bcrypt.lib")

#define SCHEMA_VERSION 1u
#define MAX_CONFIG_BYTES (64u * 1024u)
#define CONFIG_HEADER_BYTES 104u
#define RECORD_HEADER_BYTES 56u
#define CONFIG_FIELD_COUNT 6u
#define EVENT_STAGE 1u
#define EVENT_READY 2u
#define EVENT_EXIT 3u
#define EVENT_ERROR 4u
#define READY_CONFIG_CONSUMED (1u << 0)
#define READY_HANDLES_VALID (1u << 1)
#define READY_HANDLES_INHERITABLE (1u << 2)
#define READY_PRIVATE_JOB_MEMBER (1u << 3)
#define READY_TRUSTED_PATH_DENIED (1u << 4)
#define STAGE_CONFIG_CONSUMED 1u
#define STAGE_LAUNCH_VALIDATED 2u
#define STAGE_STANDARD_HANDLES_VALIDATED 3u
#define STAGE_TIMING_CONSUMED 4u
#define TIMING_PAGE_BYTES 4096u
#define TIMING_T0_OFFSET 40u
#define TIMING_GENERATION_OFFSET 48u

static const unsigned char CONFIG_MAGIC[8] = {'C','M','U','X','B','0','0','1'};
static const unsigned char ARM_MAGIC[8] = {'C','M','U','X','A','0','0','1'};
static const unsigned char EVENT_MAGIC[8] = {'C','M','U','X','E','0','0','1'};
static const unsigned char TIMING_MAGIC[8] = {'C','M','U','X','T','0','0','1'};

typedef struct BootstrapConfig {
    unsigned char nonce[32];
    HANDLE control_read;
    HANDLE control_write;
    HANDLE standard_handles[3];
    HANDLE query_job;
    wchar_t *timing;
    wchar_t *fixture_root;
    wchar_t *target;
    char target_sha256[65];
    wchar_t *trusted_probe;
    char bootstrap_sha256[65];
    wchar_t **arguments;
    uint32_t argument_count;
} BootstrapConfig;

typedef struct BufferCursor {
    const unsigned char *bytes;
    size_t length;
    size_t offset;
} BufferCursor;

typedef struct TimingPage {
    HANDLE file;
    HANDLE mapping;
    unsigned char *view;
    unsigned char nonce[32];
} TimingPage;

static uint32_t read_u32(const unsigned char *value) {
    return (uint32_t)value[0]
        | ((uint32_t)value[1] << 8)
        | ((uint32_t)value[2] << 16)
        | ((uint32_t)value[3] << 24);
}

static uint64_t read_u64(const unsigned char *value) {
    uint64_t result = 0;
    unsigned int index;
    for (index = 0; index < 8; ++index) {
        result |= ((uint64_t)value[index]) << (index * 8);
    }
    return result;
}

static void write_u32(unsigned char *value, uint32_t number) {
    value[0] = (unsigned char)(number & 0xffu);
    value[1] = (unsigned char)((number >> 8) & 0xffu);
    value[2] = (unsigned char)((number >> 16) & 0xffu);
    value[3] = (unsigned char)((number >> 24) & 0xffu);
}

static int write_all(HANDLE handle, const unsigned char *bytes, DWORD length) {
    DWORD offset = 0;
    while (offset < length) {
        DWORD written = 0;
        if (!WriteFile(handle, bytes + offset, length - offset, &written, NULL) || written == 0) {
            return 0;
        }
        offset += written;
    }
    return 1;
}

static int read_all(HANDLE handle, unsigned char *bytes, DWORD length) {
    DWORD offset = 0;
    while (offset < length) {
        DWORD count = 0;
        if (!ReadFile(handle, bytes + offset, length - offset, &count, NULL) || count == 0) {
            return 0;
        }
        offset += count;
    }
    return 1;
}

static int send_event(
    HANDLE output,
    const unsigned char nonce[32],
    uint32_t type,
    uint32_t flags,
    const unsigned char *payload,
    uint32_t payload_length
) {
    unsigned char record[RECORD_HEADER_BYTES + 32];
    uint32_t total = RECORD_HEADER_BYTES + payload_length;
    if (payload_length > 32u) {
        SetLastError(ERROR_BUFFER_OVERFLOW);
        return 0;
    }
    ZeroMemory(record, sizeof(record));
    CopyMemory(record, EVENT_MAGIC, 8);
    write_u32(record + 8, SCHEMA_VERSION);
    write_u32(record + 12, total);
    write_u32(record + 16, type);
    write_u32(record + 20, flags);
    CopyMemory(record + 24, nonce, 32);
    if (payload_length != 0u) {
        CopyMemory(record + RECORD_HEADER_BYTES, payload, payload_length);
    }
    return write_all(output, record, total);
}

static int send_stage(HANDLE output, const unsigned char nonce[32], uint32_t stage) {
    unsigned char payload[4];
    write_u32(payload, stage);
    return send_event(output, nonce, EVENT_STAGE, 0, payload, sizeof(payload));
}

static void send_error(HANDLE output, const unsigned char nonce[32], DWORD error, uint32_t stage) {
    unsigned char payload[8];
    write_u32(payload, error == ERROR_SUCCESS ? ERROR_INVALID_DATA : error);
    write_u32(payload + 4, stage);
    (void)send_event(output, nonce, EVENT_ERROR, 0, payload, sizeof(payload));
}

static int take_field(BufferCursor *cursor, const unsigned char **value, uint32_t *length) {
    uint32_t field_length;
    if (cursor->offset > cursor->length || cursor->length - cursor->offset < 4u) {
        return 0;
    }
    field_length = read_u32(cursor->bytes + cursor->offset);
    cursor->offset += 4u;
    if ((size_t)field_length > cursor->length - cursor->offset) {
        return 0;
    }
    *value = cursor->bytes + cursor->offset;
    *length = field_length;
    cursor->offset += field_length;
    return 1;
}

static wchar_t *take_utf16(BufferCursor *cursor) {
    const unsigned char *value;
    uint32_t length;
    wchar_t *result;
    size_t units;
    if (!take_field(cursor, &value, &length) || length == 0u || (length & 1u) != 0u) {
        return NULL;
    }
    units = length / sizeof(wchar_t);
    if (units > (SIZE_MAX / sizeof(wchar_t)) - 1u) {
        return NULL;
    }
    result = (wchar_t *)calloc(units + 1u, sizeof(wchar_t));
    if (result == NULL) {
        return NULL;
    }
    CopyMemory(result, value, length);
    if (wmemchr(result, L'\0', units) != NULL) {
        free(result);
        return NULL;
    }
    return result;
}

static int take_hash(BufferCursor *cursor, char output[65]) {
    const unsigned char *value;
    uint32_t length;
    uint32_t index;
    if (!take_field(cursor, &value, &length) || length != 64u) {
        return 0;
    }
    for (index = 0; index < 64u; ++index) {
        unsigned char byte = value[index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')
              || (byte >= 'A' && byte <= 'F'))) {
            return 0;
        }
        output[index] = (char)byte;
    }
    output[64] = '\0';
    return 1;
}

static void free_config(BootstrapConfig *config) {
    uint32_t index;
    free(config->timing);
    free(config->fixture_root);
    free(config->target);
    free(config->trusted_probe);
    if (config->arguments != NULL) {
        for (index = 0; index < config->argument_count; ++index) {
            free(config->arguments[index]);
        }
    }
    free(config->arguments);
    ZeroMemory(config, sizeof(*config));
}

static int parse_config(
    const unsigned char *bytes,
    size_t length,
    BootstrapConfig *config
) {
    BufferCursor cursor;
    uint32_t index;
    uint32_t argument_count;
    if (length < CONFIG_HEADER_BYTES || length > MAX_CONFIG_BYTES
        || memcmp(bytes, CONFIG_MAGIC, 8) != 0
        || read_u32(bytes + 8) != SCHEMA_VERSION
        || read_u32(bytes + 12) != (uint32_t)length
        || read_u32(bytes + 16) != CONFIG_FIELD_COUNT) {
        return 0;
    }
    argument_count = read_u32(bytes + 20);
    if (argument_count > 1024u) {
        return 0;
    }
    ZeroMemory(config, sizeof(*config));
    CopyMemory(config->nonce, bytes + 24, 32);
    config->control_read = (HANDLE)(uintptr_t)read_u64(bytes + 56);
    config->control_write = (HANDLE)(uintptr_t)read_u64(bytes + 64);
    config->standard_handles[0] = (HANDLE)(uintptr_t)read_u64(bytes + 72);
    config->standard_handles[1] = (HANDLE)(uintptr_t)read_u64(bytes + 80);
    config->standard_handles[2] = (HANDLE)(uintptr_t)read_u64(bytes + 88);
    config->query_job = (HANDLE)(uintptr_t)read_u64(bytes + 96);
    if (config->control_read == NULL || config->control_write == NULL
        || config->standard_handles[0] == NULL || config->standard_handles[1] == NULL
        || config->standard_handles[2] == NULL || config->query_job == NULL) {
        return 0;
    }
    cursor.bytes = bytes;
    cursor.length = length;
    cursor.offset = CONFIG_HEADER_BYTES;
    config->timing = take_utf16(&cursor);
    config->fixture_root = take_utf16(&cursor);
    config->target = take_utf16(&cursor);
    if (config->timing == NULL || config->fixture_root == NULL || config->target == NULL
        || !take_hash(&cursor, config->target_sha256)) {
        free_config(config);
        return 0;
    }
    config->trusted_probe = take_utf16(&cursor);
    if (config->trusted_probe == NULL || !take_hash(&cursor, config->bootstrap_sha256)) {
        free_config(config);
        return 0;
    }
    config->argument_count = argument_count;
    if (argument_count != 0u) {
        config->arguments = (wchar_t **)calloc(argument_count, sizeof(wchar_t *));
        if (config->arguments == NULL) {
            free_config(config);
            return 0;
        }
    }
    for (index = 0; index < argument_count; ++index) {
        config->arguments[index] = take_utf16(&cursor);
        if (config->arguments[index] == NULL) {
            free_config(config);
            return 0;
        }
    }
    if (cursor.offset != cursor.length) {
        free_config(config);
        return 0;
    }
    return 1;
}

static unsigned char *read_config_file(const wchar_t *path, size_t *length_out) {
    HANDLE file;
    LARGE_INTEGER size;
    unsigned char *bytes;
    DWORD count;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return NULL;
    }
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0
        || size.QuadPart > (LONGLONG)MAX_CONFIG_BYTES) {
        CloseHandle(file);
        SetLastError(ERROR_BAD_LENGTH);
        return NULL;
    }
    bytes = (unsigned char *)malloc((size_t)size.QuadPart);
    if (bytes == NULL) {
        CloseHandle(file);
        SetLastError(ERROR_OUTOFMEMORY);
        return NULL;
    }
    count = (DWORD)size.QuadPart;
    if (!read_all(file, bytes, count)) {
        DWORD error = GetLastError();
        free(bytes);
        CloseHandle(file);
        SetLastError(error);
        return NULL;
    }
    CloseHandle(file);
    *length_out = count;
    return bytes;
}

static void hex_bytes(const unsigned char *bytes, size_t length, char *output) {
    static const char HEX[] = "0123456789abcdef";
    size_t index;
    for (index = 0; index < length; ++index) {
        output[index * 2] = HEX[bytes[index] >> 4];
        output[index * 2 + 1] = HEX[bytes[index] & 0x0f];
    }
    output[length * 2] = '\0';
}

static int hash_file(const wchar_t *path, char output[65]) {
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    PUCHAR object = NULL;
    unsigned char buffer[32768];
    unsigned char digest[32];
    DWORD object_bytes = 0;
    DWORD result_bytes = 0;
    DWORD read = 0;
    NTSTATUS status;
    int result = 0;
    status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0);
    if (status < 0) goto cleanup;
    status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_bytes,
        sizeof(object_bytes), &result_bytes, 0);
    if (status < 0 || result_bytes != sizeof(object_bytes)) goto cleanup;
    object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_bytes);
    if (object == NULL) goto cleanup;
    status = BCryptCreateHash(algorithm, &hash, object, object_bytes, NULL, 0, 0);
    if (status < 0) goto cleanup;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) goto cleanup;
    for (;;) {
        if (!ReadFile(file, buffer, sizeof(buffer), &read, NULL)) goto cleanup;
        if (read == 0) break;
        status = BCryptHashData(hash, buffer, read, 0);
        if (status < 0) goto cleanup;
    }
    status = BCryptFinishHash(hash, digest, sizeof(digest), 0);
    if (status < 0) goto cleanup;
    hex_bytes(digest, sizeof(digest), output);
    result = 1;
cleanup:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (hash != NULL) BCryptDestroyHash(hash);
    if (object != NULL) HeapFree(GetProcessHeap(), 0, object);
    if (algorithm != NULL) BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!result && GetLastError() == ERROR_SUCCESS) SetLastError(ERROR_INVALID_DATA);
    return result;
}

static wchar_t *full_path(const wchar_t *path) {
    DWORD needed = GetFullPathNameW(path, 0, NULL, NULL);
    wchar_t *result;
    if (needed == 0) return NULL;
    result = (wchar_t *)calloc((size_t)needed + 1u, sizeof(wchar_t));
    if (result == NULL) return NULL;
    if (GetFullPathNameW(path, needed + 1u, result, NULL) == 0) {
        free(result);
        return NULL;
    }
    return result;
}

static void trim_trailing_separators(wchar_t *path) {
    size_t length = wcslen(path);
    while (length > 3u && (path[length - 1u] == L'\\' || path[length - 1u] == L'/')) {
        path[--length] = L'\0';
    }
}

static int path_is_within(const wchar_t *path, const wchar_t *root) {
    size_t root_length = wcslen(root);
    return wcslen(path) > root_length && _wcsnicmp(path, root, root_length) == 0
        && (path[root_length] == L'\\' || path[root_length] == L'/');
}

static int parent_is(const wchar_t *path, const wchar_t *root) {
    wchar_t *copy = _wcsdup(path);
    wchar_t *separator;
    int result;
    if (copy == NULL) return 0;
    separator = wcsrchr(copy, L'\\');
    if (separator == NULL) separator = wcsrchr(copy, L'/');
    if (separator == NULL) {
        free(copy);
        return 0;
    }
    *separator = L'\0';
    trim_trailing_separators(copy);
    result = _wcsicmp(copy, root) == 0;
    free(copy);
    return result;
}

static int config_name_matches_nonce(const wchar_t *path, const unsigned char nonce[32]) {
    wchar_t expected[39];
    static const wchar_t HEX[] = L"0123456789abcdef";
    const wchar_t *name = wcsrchr(path, L'\\');
    unsigned int index;
    name = name == NULL ? path : name + 1;
    wcscpy(expected, L"bootstrap-");
    for (index = 0; index < 8; ++index) {
        expected[10 + index * 2] = HEX[nonce[index] >> 4];
        expected[11 + index * 2] = HEX[nonce[index] & 0x0f];
    }
    wcscpy(expected + 26, L".bin");
    return _wcsicmp(name, expected) == 0;
}

static int validate_paths(const wchar_t *config_path, const BootstrapConfig *config) {
    wchar_t *fixture = full_path(config->fixture_root);
    wchar_t *target = full_path(config->target);
    wchar_t *timing = full_path(config->timing);
    wchar_t *probe = full_path(config->trusted_probe);
    wchar_t *config_full = full_path(config_path);
    DWORD fixture_attributes;
    DWORD target_attributes;
    DWORD timing_attributes;
    DWORD probe_attributes;
    int valid = 0;
    if (fixture == NULL || target == NULL || timing == NULL || probe == NULL
        || config_full == NULL) goto cleanup;
    trim_trailing_separators(fixture);
    fixture_attributes = GetFileAttributesW(fixture);
    target_attributes = GetFileAttributesW(target);
    timing_attributes = GetFileAttributesW(timing);
    probe_attributes = GetFileAttributesW(probe);
    valid = fixture_attributes != INVALID_FILE_ATTRIBUTES
        && (fixture_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
        && target_attributes != INVALID_FILE_ATTRIBUTES
        && (target_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
        && timing_attributes != INVALID_FILE_ATTRIBUTES
        && (timing_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
        && probe_attributes != INVALID_FILE_ATTRIBUTES
        && (probe_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
        && !path_is_within(target, fixture)
        && !path_is_within(probe, fixture)
        && parent_is(timing, fixture)
        && parent_is(config_full, fixture)
        && config_name_matches_nonce(config_full, config->nonce);
cleanup:
    free(fixture);
    free(target);
    free(timing);
    free(probe);
    free(config_full);
    if (!valid) SetLastError(ERROR_ACCESS_DENIED);
    return valid;
}

static int trusted_path_write_denied(const wchar_t *path) {
    HANDLE handle = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        SetLastError(ERROR_ACCESS_DENIED);
        return 0;
    }
    return GetLastError() == ERROR_ACCESS_DENIED;
}

static int validate_handles(const BootstrapConfig *config, int *all_inheritable) {
    unsigned int index;
    *all_inheritable = 1;
    for (index = 0; index < 3; ++index) {
        DWORD flags = 0;
        SetLastError(ERROR_SUCCESS);
        if (GetFileType(config->standard_handles[index]) == FILE_TYPE_UNKNOWN
            && GetLastError() != ERROR_SUCCESS) return 0;
        if (!GetHandleInformation(config->standard_handles[index], &flags)) return 0;
        if ((flags & HANDLE_FLAG_INHERIT) == 0) *all_inheritable = 0;
    }
    return 1;
}

static int open_timing(const BootstrapConfig *config, TimingPage *timing) {
    LARGE_INTEGER size;
    ZeroMemory(timing, sizeof(*timing));
    timing->file = CreateFileW(config->timing, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, NULL);
    if (timing->file == INVALID_HANDLE_VALUE) return 0;
    if (!GetFileSizeEx(timing->file, &size) || size.QuadPart != TIMING_PAGE_BYTES) return 0;
    timing->mapping = CreateFileMappingW(timing->file, NULL, PAGE_READWRITE, 0, TIMING_PAGE_BYTES, NULL);
    if (timing->mapping == NULL) return 0;
    timing->view = (unsigned char *)MapViewOfFile(timing->mapping, FILE_MAP_ALL_ACCESS, 0, 0,
        TIMING_PAGE_BYTES);
    if (timing->view == NULL) return 0;
    if (memcmp(timing->view, TIMING_MAGIC, 8) != 0
        || memcmp(timing->view + 8, config->nonce, 32) != 0) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    CopyMemory(timing->nonce, config->nonce, 32);
    if (!DeleteFileW(config->timing)) return 0;
    return 1;
}

static void close_timing(TimingPage *timing) {
    if (timing->view != NULL) UnmapViewOfFile(timing->view);
    if (timing->mapping != NULL) CloseHandle(timing->mapping);
    if (timing->file != NULL && timing->file != INVALID_HANDLE_VALUE) CloseHandle(timing->file);
    ZeroMemory(timing, sizeof(*timing));
}

static int record_t0(TimingPage *timing) {
    LARGE_INTEGER counter;
    LARGE_INTEGER frequency;
    uint64_t nanoseconds;
    uint64_t seconds;
    uint64_t remainder;
    uint64_t high;
    uint64_t low;
    uint64_t unused_remainder;
    volatile LONG64 *generation = (volatile LONG64 *)(timing->view + TIMING_GENERATION_OFFSET);
    volatile LONG64 *t0 = (volatile LONG64 *)(timing->view + TIMING_T0_OFFSET);
    if (memcmp(timing->view + 8, timing->nonce, 32) != 0) return 0;
    if (InterlockedCompareExchange64(generation, -1, 0) != 0) {
        SetLastError(ERROR_ALREADY_EXISTS);
        return 0;
    }
    if (!QueryPerformanceCounter(&counter) || !QueryPerformanceFrequency(&frequency)
        || counter.QuadPart < 0 || frequency.QuadPart <= 0) return 0;
    seconds = (uint64_t)(counter.QuadPart / frequency.QuadPart);
    remainder = (uint64_t)(counter.QuadPart % frequency.QuadPart);
    if (seconds > UINT64_MAX / 1000000000ull) {
        SetLastError(ERROR_ARITHMETIC_OVERFLOW);
        return 0;
    }
    low = _umul128(remainder, 1000000000ull, &high);
    nanoseconds = seconds * 1000000000ull
        + _udiv128(high, low, (uint64_t)frequency.QuadPart, &unused_remainder);
    InterlockedExchange64(t0, (LONG64)nanoseconds);
    InterlockedExchange64(generation, 1);
    return 1;
}

static size_t quoted_length(const wchar_t *value) {
    size_t length = 2u;
    size_t slashes = 0u;
    const wchar_t *cursor;
    for (cursor = value; *cursor != L'\0'; ++cursor) {
        if (*cursor == L'\\') {
            ++slashes;
        } else if (*cursor == L'"') {
            length += slashes * 2u + 2u;
            slashes = 0u;
        } else {
            length += slashes + 1u;
            slashes = 0u;
        }
    }
    return length + slashes * 2u;
}

static wchar_t *append_quoted(wchar_t *output, const wchar_t *value) {
    size_t slashes = 0u;
    const wchar_t *cursor;
    *output++ = L'"';
    for (cursor = value; *cursor != L'\0'; ++cursor) {
        if (*cursor == L'\\') {
            ++slashes;
        } else if (*cursor == L'"') {
            while (slashes != 0u) {
                *output++ = L'\\';
                *output++ = L'\\';
                --slashes;
            }
            *output++ = L'\\';
            *output++ = L'"';
            slashes = 0u;
        } else {
            while (slashes != 0u) {
                *output++ = L'\\';
                --slashes;
            }
            *output++ = *cursor;
            slashes = 0u;
        }
    }
    while (slashes != 0u) {
        *output++ = L'\\';
        *output++ = L'\\';
        --slashes;
    }
    *output++ = L'"';
    return output;
}

static wchar_t *product_command_line(const BootstrapConfig *config) {
    size_t total = quoted_length(config->target) + 1u;
    uint32_t index;
    wchar_t *line;
    wchar_t *cursor;
    for (index = 0; index < config->argument_count; ++index) {
        size_t addition = quoted_length(config->arguments[index]) + 1u;
        if (total > SIZE_MAX - addition) return NULL;
        total += addition;
    }
    line = (wchar_t *)calloc(total, sizeof(wchar_t));
    if (line == NULL) return NULL;
    cursor = append_quoted(line, config->target);
    for (index = 0; index < config->argument_count; ++index) {
        *cursor++ = L' ';
        cursor = append_quoted(cursor, config->arguments[index]);
    }
    *cursor = L'\0';
    return line;
}

static int create_product(
    const BootstrapConfig *config,
    TimingPage *timing,
    DWORD *exit_code,
    int *contained
) {
    SIZE_T attribute_bytes = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION process;
    HANDLE handles[3];
    wchar_t *command_line = NULL;
    DWORD resume_count;
    int result = 0;
    int attributes_initialized = 0;
    handles[0] = config->standard_handles[0];
    handles[1] = config->standard_handles[1];
    handles[2] = config->standard_handles[2];
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
    attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_bytes);
    if (attributes == NULL) goto cleanup;
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes)) goto cleanup;
    attributes_initialized = 1;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        handles, sizeof(handles), NULL, NULL)) goto cleanup;
    command_line = product_command_line(config);
    if (command_line == NULL) goto cleanup;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = handles[0];
    startup.StartupInfo.hStdOutput = handles[1];
    startup.StartupInfo.hStdError = handles[2];
    startup.lpAttributeList = attributes;
    if (!record_t0(timing)) goto cleanup;
    if (!CreateProcessW(config->target, command_line, NULL, NULL, TRUE,
        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, NULL, config->fixture_root,
        &startup.StartupInfo, &process)) goto cleanup;
    if (!IsProcessInJob(process.hProcess, config->query_job, contained) || !*contained) {
        if (!*contained) SetLastError(ERROR_ACCESS_DENIED);
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        goto process_cleanup;
    }
    resume_count = ResumeThread(process.hThread);
    if (resume_count != 1u) {
        if (resume_count == (DWORD)-1) SetLastError(GetLastError());
        else SetLastError(ERROR_INVALID_PARAMETER);
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        goto process_cleanup;
    }
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, exit_code)) goto process_cleanup;
    result = 1;
process_cleanup:
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
cleanup:
    free(command_line);
    if (attributes != NULL) {
        if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);
    }
    return result;
}

static int read_arm(HANDLE input, const unsigned char nonce[32]) {
    unsigned char record[48];
    return read_all(input, record, sizeof(record))
        && memcmp(record, ARM_MAGIC, 8) == 0
        && read_u32(record + 8) == SCHEMA_VERSION
        && read_u32(record + 12) == sizeof(record)
        && memcmp(record + 16, nonce, 32) == 0;
}

static int bootstrap_run(const wchar_t *config_path) {
    unsigned char *bytes = NULL;
    size_t length = 0;
    BootstrapConfig config;
    wchar_t self_path[32768];
    char observed_bootstrap_sha256[65];
    char observed_target_sha256[65];
    int handles_inheritable = 0;
    int bootstrap_in_job = 0;
    int trusted_denied = 0;
    TimingPage timing;
    DWORD exit_code = 125;
    int product_contained = 0;
    unsigned char payload[32];
    uint32_t flags;
    DWORD query_handle_flags = 0;
    DWORD error;
    uint32_t stage = 0;
    int result = 0;
    ZeroMemory(&config, sizeof(config));
    ZeroMemory(&timing, sizeof(timing));
    bytes = read_config_file(config_path, &length);
    if (bytes == NULL || !parse_config(bytes, length, &config)) {
        free(bytes);
        return 125;
    }
    free(bytes);
    if (!validate_paths(config_path, &config) || !DeleteFileW(config_path)) goto failure;
    stage = STAGE_CONFIG_CONSUMED;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    if (GetModuleFileNameW(NULL, self_path, 32768) == 0
        || !hash_file(self_path, observed_bootstrap_sha256)
        || _stricmp(observed_bootstrap_sha256, config.bootstrap_sha256) != 0
        || !hash_file(config.target, observed_target_sha256)
        || _stricmp(observed_target_sha256, config.target_sha256) != 0) goto failure;
    trusted_denied = trusted_path_write_denied(config.trusted_probe);
    if (!trusted_denied) goto failure;
    stage = STAGE_LAUNCH_VALIDATED;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    if (!validate_handles(&config, &handles_inheritable) || !handles_inheritable
        || !GetHandleInformation(config.query_job, &query_handle_flags)
        || (query_handle_flags & HANDLE_FLAG_INHERIT) != 0
        || !IsProcessInJob(GetCurrentProcess(), config.query_job, &bootstrap_in_job)
        || !bootstrap_in_job) goto failure;
    stage = STAGE_STANDARD_HANDLES_VALIDATED;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    if (!open_timing(&config, &timing)) goto failure;
    stage = STAGE_TIMING_CONSUMED;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    flags = READY_CONFIG_CONSUMED | READY_HANDLES_VALID | READY_HANDLES_INHERITABLE
        | READY_PRIVATE_JOB_MEMBER | READY_TRUSTED_PATH_DENIED;
    {
        size_t index;
        for (index = 0; index < 32u; ++index) {
            unsigned int high;
            unsigned int low;
            char a = observed_bootstrap_sha256[index * 2u];
            char b = observed_bootstrap_sha256[index * 2u + 1u];
            high = (unsigned int)(a <= '9' ? a - '0' : (a | 32) - 'a' + 10);
            low = (unsigned int)(b <= '9' ? b - '0' : (b | 32) - 'a' + 10);
            payload[index] = (unsigned char)((high << 4) | low);
        }
    }
    if (!send_event(config.control_write, config.nonce, EVENT_READY, flags,
        payload, sizeof(payload))) goto failure;
    if (!read_arm(config.control_read, config.nonce)) goto failure;
    if (!create_product(&config, &timing, &exit_code, &product_contained)) goto failure;
    write_u32(payload, exit_code);
    write_u32(payload + 4, product_contained ? 1u : 0u);
    if (!send_event(config.control_write, config.nonce, EVENT_EXIT, 0, payload, 8)) goto failure;
    result = (int)exit_code;
    goto cleanup;
failure:
    error = GetLastError();
    send_error(config.control_write, config.nonce, error, stage);
    result = 125;
cleanup:
    close_timing(&timing);
    if (config.control_read != NULL) CloseHandle(config.control_read);
    if (config.control_write != NULL) CloseHandle(config.control_write);
    if (config.standard_handles[0] != NULL) CloseHandle(config.standard_handles[0]);
    if (config.standard_handles[1] != NULL) CloseHandle(config.standard_handles[1]);
    if (config.standard_handles[2] != NULL) CloseHandle(config.standard_handles[2]);
    if (config.query_job != NULL) CloseHandle(config.query_job);
    free_config(&config);
    return result;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 125;
    return bootstrap_run(argv[1]);
}
