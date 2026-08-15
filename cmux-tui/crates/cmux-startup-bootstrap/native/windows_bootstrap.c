#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <intrin.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <sddl.h>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")

#define SCHEMA_VERSION 5u
#define MAX_CONFIG_BYTES (64u * 1024u)
#define MAX_WIDE_CHARS 32767u
#define CONFIG_HEADER_BYTES 104u
#define RECORD_HEADER_BYTES 56u
#define CONFIG_FIELD_COUNT 8u
#define EVENT_STAGE 1u
#define EVENT_READY 2u
#define EVENT_EXIT 3u
#define EVENT_ERROR 4u
#define EVENT_PRODUCT_STARTED 5u
#define READY_CONFIG_CONSUMED (1u << 0)
#define READY_HANDLES_VALID (1u << 1)
#define READY_HANDLES_INHERITABLE (1u << 2)
#define READY_PRIVATE_JOB_MEMBER (1u << 3)
#define READY_TRUSTED_PATH_DENIED (1u << 4)
#define READY_BOOTSTRAP_WRITE_DENIED (1u << 5)
#define READY_SE_INCREASE_QUOTA_PRESENT (1u << 6)
#define READY_SE_INCREASE_QUOTA_ENABLED (1u << 7)
#define READY_RESTRICTED_TOKEN (1u << 8)
#define READY_RESTRICTED_LOW_INTEGRITY (1u << 9)
#define READY_RESTRICTED_NO_ENABLED_PRIVILEGES (1u << 10)
#define READY_RESTRICTED_AUTHENTICATION_MATCH (1u << 11)
#define READY_RESTRICTING_SID_MATCH (1u << 12)
#define READY_WRITE_RESTRICTED_CREATED (1u << 13)
#define EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED (1u << 0)
#define EXIT_PRODUCT_AUTHENTICATION_MATCH (1u << 1)
#define EXIT_PRODUCT_LOW_INTEGRITY (1u << 2)
#define EXIT_PRODUCT_WRITE_RESTRICTED (1u << 3)
#define EXIT_PRODUCT_NO_ENABLED_PRIVILEGES (1u << 4)
#define EXIT_PRODUCT_RESTRICTING_SID_MATCH (1u << 5)
#define MAX_RESTRICTING_SID_BYTES 184u
#define STAGE_CONFIG_CONSUMED 1u
#define STAGE_LAUNCH_VALIDATED 2u
#define STAGE_STANDARD_HANDLES_VALIDATED 3u
#define STAGE_TIMING_CONSUMED 4u
#define STAGE_NATIVE_ENTRY_REACHED 5u
#define STAGE_NATIVE_CONFIG_READ_STARTED 6u
#define STAGE_RESTRICTED_PRODUCT_TOKEN_READY 7u
#define ENTRY_STAGE_REACHED 1u
#define ENTRY_STAGE_CONFIG_READ_STARTED 2u
#define ENTRY_STAGE_CONFIG_CONSUMED 3u
#define ENTRY_CHECKPOINT_BYTES 48u
#define TIMING_PAGE_BYTES 4096u
#define TIMING_T0_OFFSET 40u
#define TIMING_GENERATION_OFFSET 48u

static const unsigned char CONFIG_MAGIC[8] = {'C','M','U','X','B','0','0','1'};
static const unsigned char ARM_MAGIC[8] = {'C','M','U','X','A','0','0','1'};
static const unsigned char PRODUCT_HANDLES_ADOPTED_MAGIC[8] = {'C','M','U','X','K','0','0','1'};
static const unsigned char EVENT_MAGIC[8] = {'C','M','U','X','E','0','0','1'};
static const unsigned char ENTRY_MAGIC[8] = {'C','M','U','X','N','0','0','1'};
static const unsigned char TIMING_MAGIC[8] = {'C','M','U','X','T','0','0','1'};
static const WCHAR ENTRY_CHECKPOINT_PATH_ENV[] =
    L"CMUX_BENCH_BOOTSTRAP_ENTRY_CHECKPOINT";
static const WCHAR ENTRY_NONCE_ENV[] = L"CMUX_BENCH_BOOTSTRAP_ENTRY_NONCE";

void __cdecl __security_init_cookie(void);

typedef struct BootstrapConfig {
    unsigned char nonce[32];
    HANDLE control_read;
    HANDLE control_write;
    HANDLE standard_handles[3];
    HANDLE query_job;
    WCHAR *timing;
    WCHAR *fixture_root;
    WCHAR *target;
    char target_sha256[65];
    WCHAR *trusted_probe;
    char bootstrap_sha256[65];
    char restricting_sid[MAX_RESTRICTING_SID_BYTES + 1u];
    WCHAR *private_desktop;
    WCHAR **arguments;
    uint32_t argument_count;
} BootstrapConfig;

typedef struct BufferCursor {
    const unsigned char *bytes;
    SIZE_T length;
    SIZE_T offset;
} BufferCursor;

typedef struct TimingPage {
    HANDLE file;
    HANDLE mapping;
    unsigned char *view;
    unsigned char nonce[32];
} TimingPage;

typedef struct EntryArguments {
    WCHAR *config_path;
    WCHAR *checkpoint_path;
    WCHAR *nonce_text;
    unsigned char nonce[32];
} EntryArguments;

typedef struct EntryCheckpointIdentity {
    WCHAR *checkpoint_path;
    unsigned char nonce[32];
} EntryCheckpointIdentity;

static void memory_zero(void *target, SIZE_T length) {
    volatile unsigned char *output = (volatile unsigned char *)target;
    SIZE_T index;
    for (index = 0; index < length; ++index) output[index] = 0;
}

static void memory_copy(void *target, const void *source, SIZE_T length) {
    volatile unsigned char *output = (volatile unsigned char *)target;
    const volatile unsigned char *input = (const volatile unsigned char *)source;
    SIZE_T index;
    for (index = 0; index < length; ++index) output[index] = input[index];
}

static int bytes_equal(const void *left, const void *right, SIZE_T length) {
    const volatile unsigned char *a = (const volatile unsigned char *)left;
    const volatile unsigned char *b = (const volatile unsigned char *)right;
    SIZE_T index;
    unsigned char difference = 0;
    for (index = 0; index < length; ++index) difference |= (unsigned char)(a[index] ^ b[index]);
    return difference == 0;
}

static void *heap_array(SIZE_T count, SIZE_T item_bytes, int zero) {
    SIZE_T bytes;
    if (item_bytes != 0 && count > SIZE_MAX / item_bytes) {
        SetLastError(ERROR_ARITHMETIC_OVERFLOW);
        return NULL;
    }
    bytes = count * item_bytes;
    if (bytes == 0) bytes = 1;
    return HeapAlloc(GetProcessHeap(), zero ? HEAP_ZERO_MEMORY : 0, bytes);
}

static void heap_release(void *value) {
    if (value != NULL) (void)HeapFree(GetProcessHeap(), 0, value);
}

static SIZE_T wide_length(const WCHAR *value) {
    SIZE_T length = 0;
    if (value == NULL) return SIZE_MAX;
    while (length <= MAX_WIDE_CHARS && value[length] != L'\0') ++length;
    return length <= MAX_WIDE_CHARS ? length : SIZE_MAX;
}

static WCHAR *wide_duplicate(const WCHAR *value) {
    SIZE_T length = wide_length(value);
    WCHAR *result;
    if (length == SIZE_MAX) return NULL;
    result = (WCHAR *)heap_array(length + 1u, sizeof(WCHAR), 1);
    if (result != NULL) memory_copy(result, value, length * sizeof(WCHAR));
    return result;
}

static int wide_equal_ignore_case(const WCHAR *left, const WCHAR *right) {
    return CompareStringOrdinal(left, -1, right, -1, TRUE) == CSTR_EQUAL;
}

static WCHAR hex_digit(unsigned char value) {
    return (WCHAR)(value < 10u ? L'0' + value : L'a' + value - 10u);
}

static int private_desktop_matches_nonce(
    const WCHAR *value,
    const unsigned char nonce[32]
) {
    static const WCHAR station_prefix[] = L"cmuxb-";
    static const WCHAR desktop_prefix[] = L"desk-";
    SIZE_T cursor = 0;
    SIZE_T index;
    if (wide_length(value) != 60u) return 0;
    for (index = 0; index < 6u; ++index) {
        if (value[cursor++] != station_prefix[index]) return 0;
    }
    for (index = 0; index < 12u; ++index) {
        if (value[cursor++] != hex_digit((unsigned char)(nonce[index] >> 4))
            || value[cursor++] != hex_digit((unsigned char)(nonce[index] & 15u))) return 0;
    }
    if (value[cursor++] != L'\\') return 0;
    for (index = 0; index < 5u; ++index) {
        if (value[cursor++] != desktop_prefix[index]) return 0;
    }
    for (index = 12u; index < 24u; ++index) {
        if (value[cursor++] != hex_digit((unsigned char)(nonce[index] >> 4))
            || value[cursor++] != hex_digit((unsigned char)(nonce[index] & 15u))) return 0;
    }
    return value[cursor] == L'\0';
}

static int wide_prefix_ignore_case(const WCHAR *value, const WCHAR *prefix, SIZE_T prefix_length) {
    SIZE_T value_length = wide_length(value);
    if (value_length == SIZE_MAX || value_length <= prefix_length || prefix_length > INT_MAX) {
        return 0;
    }
    return CompareStringOrdinal(value, (int)prefix_length, prefix, (int)prefix_length, TRUE)
        == CSTR_EQUAL;
}

static WCHAR *last_separator(WCHAR *value) {
    SIZE_T length = wide_length(value);
    if (length == SIZE_MAX) return NULL;
    while (length != 0) {
        --length;
        if (value[length] == L'\\' || value[length] == L'/') return value + length;
    }
    return NULL;
}

static const WCHAR *last_separator_const(const WCHAR *value) {
    return (const WCHAR *)last_separator((WCHAR *)value);
}

static unsigned char ascii_lower(unsigned char value) {
    return value >= 'A' && value <= 'Z' ? (unsigned char)(value + ('a' - 'A')) : value;
}

static int hash_text_equal(const char *left, const char *right) {
    SIZE_T index;
    for (index = 0; index < 64u; ++index) {
        if (ascii_lower((unsigned char)left[index]) != ascii_lower((unsigned char)right[index])) {
            return 0;
        }
    }
    return left[64] == '\0' && right[64] == '\0';
}

static uint32_t read_u32(const unsigned char *value) {
    return (uint32_t)value[0]
        | ((uint32_t)value[1] << 8)
        | ((uint32_t)value[2] << 16)
        | ((uint32_t)value[3] << 24);
}

static uint64_t read_u64(const unsigned char *value) {
    uint64_t result = 0;
    unsigned int index;
    for (index = 0; index < 8; ++index) result |= ((uint64_t)value[index]) << (index * 8);
    return result;
}

static void write_u32(unsigned char *value, uint32_t number) {
    value[0] = (unsigned char)(number & 0xffu);
    value[1] = (unsigned char)((number >> 8) & 0xffu);
    value[2] = (unsigned char)((number >> 16) & 0xffu);
    value[3] = (unsigned char)((number >> 24) & 0xffu);
}

static void write_u64(unsigned char *value, uint64_t number) {
    write_u32(value, (uint32_t)number);
    write_u32(value + 4, (uint32_t)(number >> 32));
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
    unsigned char record[RECORD_HEADER_BYTES + 256];
    uint32_t total = RECORD_HEADER_BYTES + payload_length;
    if (payload_length > 256u) {
        SetLastError(ERROR_BUFFER_OVERFLOW);
        return 0;
    }
    memory_zero(record, sizeof(record));
    memory_copy(record, EVENT_MAGIC, 8);
    write_u32(record + 8, SCHEMA_VERSION);
    write_u32(record + 12, total);
    write_u32(record + 16, type);
    write_u32(record + 20, flags);
    memory_copy(record + 24, nonce, 32);
    if (payload_length != 0u) memory_copy(record + RECORD_HEADER_BYTES, payload, payload_length);
    return write_all(output, record, total);
}

static int send_stage(HANDLE output, const unsigned char nonce[32], uint32_t stage) {
    unsigned char payload[4];
    write_u32(payload, stage);
    return send_event(output, nonce, EVENT_STAGE, 0, payload, (uint32_t)sizeof(payload));
}

static void send_error(HANDLE output, const unsigned char nonce[32], DWORD error, uint32_t stage) {
    unsigned char payload[8];
    write_u32(payload, error == ERROR_SUCCESS ? ERROR_INVALID_DATA : error);
    write_u32(payload + 4, stage);
    (void)send_event(output, nonce, EVENT_ERROR, 0, payload, (uint32_t)sizeof(payload));
}

static int take_field(BufferCursor *cursor, const unsigned char **value, uint32_t *length) {
    uint32_t field_length;
    if (cursor->offset > cursor->length || cursor->length - cursor->offset < 4u) return 0;
    field_length = read_u32(cursor->bytes + cursor->offset);
    cursor->offset += 4u;
    if ((SIZE_T)field_length > cursor->length - cursor->offset) return 0;
    *value = cursor->bytes + cursor->offset;
    *length = field_length;
    cursor->offset += field_length;
    return 1;
}

static WCHAR *take_utf16(BufferCursor *cursor) {
    const unsigned char *value;
    uint32_t length;
    WCHAR *result;
    SIZE_T units;
    SIZE_T index;
    if (!take_field(cursor, &value, &length) || length == 0u || (length & 1u) != 0u) return NULL;
    units = length / sizeof(WCHAR);
    if (units > MAX_WIDE_CHARS) return NULL;
    result = (WCHAR *)heap_array(units + 1u, sizeof(WCHAR), 1);
    if (result == NULL) return NULL;
    memory_copy(result, value, length);
    for (index = 0; index < units; ++index) {
        if (result[index] == L'\0') {
            heap_release(result);
            return NULL;
        }
    }
    return result;
}

static int take_hash(BufferCursor *cursor, char output[65]) {
    const unsigned char *value;
    uint32_t length;
    uint32_t index;
    if (!take_field(cursor, &value, &length) || length != 64u) return 0;
    for (index = 0; index < 64u; ++index) {
        unsigned char byte = value[index];
        if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')
              || (byte >= 'A' && byte <= 'F'))) return 0;
        output[index] = (char)byte;
    }
    output[64] = '\0';
    return 1;
}

static int take_sid(BufferCursor *cursor, char output[MAX_RESTRICTING_SID_BYTES + 1u]) {
    const unsigned char *value;
    uint32_t length;
    uint32_t index;
    if (!take_field(cursor, &value, &length) || length < 5u || length > MAX_RESTRICTING_SID_BYTES) {
        return 0;
    }
    for (index = 0; index < length; ++index) {
        unsigned char byte = value[index];
        if (!((byte >= '0' && byte <= '9') || byte == '-' || byte == 'S')) return 0;
        output[index] = (char)byte;
    }
    output[length] = '\0';
    return output[0] == 'S' && output[1] == '-' && output[2] == '1' && output[3] == '-';
}

static void free_config(BootstrapConfig *config) {
    uint32_t index;
    heap_release(config->timing);
    heap_release(config->fixture_root);
    heap_release(config->target);
    heap_release(config->trusted_probe);
    heap_release(config->private_desktop);
    if (config->arguments != NULL) {
        for (index = 0; index < config->argument_count; ++index) {
            heap_release(config->arguments[index]);
        }
    }
    heap_release(config->arguments);
    memory_zero(config, sizeof(*config));
}

static int parse_config(const unsigned char *bytes, SIZE_T length, BootstrapConfig *config) {
    BufferCursor cursor;
    uint32_t index;
    uint32_t argument_count;
    if (length < CONFIG_HEADER_BYTES || length > MAX_CONFIG_BYTES
        || !bytes_equal(bytes, CONFIG_MAGIC, 8)
        || read_u32(bytes + 8) != SCHEMA_VERSION
        || read_u32(bytes + 12) != (uint32_t)length
        || read_u32(bytes + 16) != CONFIG_FIELD_COUNT) return 0;
    argument_count = read_u32(bytes + 20);
    if (argument_count > 1024u) return 0;
    memory_zero(config, sizeof(*config));
    memory_copy(config->nonce, bytes + 24, 32);
    config->control_read = (HANDLE)(uintptr_t)read_u64(bytes + 56);
    config->control_write = (HANDLE)(uintptr_t)read_u64(bytes + 64);
    config->standard_handles[0] = (HANDLE)(uintptr_t)read_u64(bytes + 72);
    config->standard_handles[1] = (HANDLE)(uintptr_t)read_u64(bytes + 80);
    config->standard_handles[2] = (HANDLE)(uintptr_t)read_u64(bytes + 88);
    config->query_job = (HANDLE)(uintptr_t)read_u64(bytes + 96);
    if (config->control_read == NULL || config->control_write == NULL
        || config->standard_handles[0] == NULL || config->standard_handles[1] == NULL
        || config->standard_handles[2] == NULL || config->query_job == NULL) return 0;
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
    if (config->trusted_probe == NULL || !take_hash(&cursor, config->bootstrap_sha256)
        || !take_sid(&cursor, config->restricting_sid)) {
        free_config(config);
        return 0;
    }
    config->private_desktop = take_utf16(&cursor);
    if (config->private_desktop == NULL
        || !private_desktop_matches_nonce(config->private_desktop, config->nonce)) {
        free_config(config);
        return 0;
    }
    config->argument_count = argument_count;
    if (argument_count != 0u) {
        config->arguments = (WCHAR **)heap_array(argument_count, sizeof(WCHAR *), 1);
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

static unsigned char *read_config_file(const WCHAR *path, SIZE_T *length_out) {
    HANDLE file;
    LARGE_INTEGER size;
    unsigned char *bytes;
    DWORD count;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0
        || size.QuadPart > (LONGLONG)MAX_CONFIG_BYTES) {
        CloseHandle(file);
        SetLastError(ERROR_BAD_LENGTH);
        return NULL;
    }
    bytes = (unsigned char *)heap_array((SIZE_T)size.QuadPart, 1, 0);
    if (bytes == NULL) {
        CloseHandle(file);
        SetLastError(ERROR_OUTOFMEMORY);
        return NULL;
    }
    count = (DWORD)size.QuadPart;
    if (!read_all(file, bytes, count)) {
        DWORD error = GetLastError();
        heap_release(bytes);
        CloseHandle(file);
        SetLastError(error);
        return NULL;
    }
    CloseHandle(file);
    *length_out = count;
    return bytes;
}

static void hex_bytes(const unsigned char *bytes, SIZE_T length, char *output) {
    static const char HEX[] = "0123456789abcdef";
    SIZE_T index;
    for (index = 0; index < length; ++index) {
        output[index * 2] = HEX[bytes[index] >> 4];
        output[index * 2 + 1] = HEX[bytes[index] & 0x0f];
    }
    output[length * 2] = '\0';
}

static int hash_file(const WCHAR *path, char output[65]) {
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
        (ULONG)sizeof(object_bytes), &result_bytes, 0);
    if (status < 0 || result_bytes != (DWORD)sizeof(object_bytes)) goto cleanup;
    object = (PUCHAR)HeapAlloc(GetProcessHeap(), 0, object_bytes);
    if (object == NULL) goto cleanup;
    status = BCryptCreateHash(algorithm, &hash, object, object_bytes, NULL, 0, 0);
    if (status < 0) goto cleanup;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) goto cleanup;
    for (;;) {
        if (!ReadFile(file, buffer, (DWORD)sizeof(buffer), &read, NULL)) goto cleanup;
        if (read == 0) break;
        status = BCryptHashData(hash, buffer, read, 0);
        if (status < 0) goto cleanup;
    }
    status = BCryptFinishHash(hash, digest, (ULONG)sizeof(digest), 0);
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

static WCHAR *full_path(const WCHAR *path) {
    DWORD needed = GetFullPathNameW(path, 0, NULL, NULL);
    WCHAR *result;
    if (needed == 0 || needed > MAX_WIDE_CHARS) return NULL;
    result = (WCHAR *)heap_array((SIZE_T)needed + 1u, sizeof(WCHAR), 1);
    if (result == NULL) return NULL;
    if (GetFullPathNameW(path, needed + 1u, result, NULL) == 0) {
        heap_release(result);
        return NULL;
    }
    return result;
}

static void trim_trailing_separators(WCHAR *path) {
    SIZE_T length = wide_length(path);
    if (length == SIZE_MAX) return;
    while (length > 3u && (path[length - 1u] == L'\\' || path[length - 1u] == L'/')) {
        path[--length] = L'\0';
    }
}

static int path_is_within(const WCHAR *path, const WCHAR *root) {
    SIZE_T root_length = wide_length(root);
    return root_length != SIZE_MAX && wide_prefix_ignore_case(path, root, root_length)
        && (path[root_length] == L'\\' || path[root_length] == L'/');
}

static int parent_is(const WCHAR *path, const WCHAR *root) {
    WCHAR *copy = wide_duplicate(path);
    WCHAR *separator;
    int result;
    if (copy == NULL) return 0;
    separator = last_separator(copy);
    if (separator == NULL) {
        heap_release(copy);
        return 0;
    }
    *separator = L'\0';
    trim_trailing_separators(copy);
    result = wide_equal_ignore_case(copy, root);
    heap_release(copy);
    return result;
}

static int name_matches_nonce(
    const WCHAR *path,
    const WCHAR *prefix,
    SIZE_T prefix_length,
    const unsigned char nonce[32]
) {
    static const WCHAR HEX[] = L"0123456789abcdef";
    const WCHAR *separator = last_separator_const(path);
    const WCHAR *name = separator == NULL ? path : separator + 1;
    SIZE_T name_length = wide_length(name);
    SIZE_T index;
    if (name_length != prefix_length + 20u) return 0;
    if (CompareStringOrdinal(name, (int)prefix_length, prefix, (int)prefix_length, TRUE)
        != CSTR_EQUAL) return 0;
    for (index = 0; index < 8u; ++index) {
        if (name[prefix_length + index * 2u] != HEX[nonce[index] >> 4]
            || name[prefix_length + index * 2u + 1u] != HEX[nonce[index] & 0x0f]) return 0;
    }
    return name[prefix_length + 16u] == L'.'
        && (name[prefix_length + 17u] == L'b' || name[prefix_length + 17u] == L'B')
        && (name[prefix_length + 18u] == L'i' || name[prefix_length + 18u] == L'I')
        && (name[prefix_length + 19u] == L'n' || name[prefix_length + 19u] == L'N');
}

static int validate_paths(
    const WCHAR *config_path,
    const WCHAR *checkpoint_path,
    const BootstrapConfig *config
) {
    static const WCHAR CONFIG_PREFIX[] = L"bootstrap-";
    static const WCHAR ENTRY_PREFIX[] = L"bootstrap-entry-";
    WCHAR *fixture = full_path(config->fixture_root);
    WCHAR *target = full_path(config->target);
    WCHAR *timing = full_path(config->timing);
    WCHAR *probe = full_path(config->trusted_probe);
    WCHAR *config_full = full_path(config_path);
    WCHAR *checkpoint_full = full_path(checkpoint_path);
    DWORD fixture_attributes;
    DWORD target_attributes;
    DWORD timing_attributes;
    DWORD probe_attributes;
    int valid = 0;
    if (fixture == NULL || target == NULL || timing == NULL || probe == NULL
        || config_full == NULL || checkpoint_full == NULL) goto cleanup;
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
        && parent_is(checkpoint_full, fixture)
        && name_matches_nonce(config_full, CONFIG_PREFIX, 10u, config->nonce)
        && name_matches_nonce(checkpoint_full, ENTRY_PREFIX, 16u, config->nonce);
cleanup:
    heap_release(fixture);
    heap_release(target);
    heap_release(timing);
    heap_release(probe);
    heap_release(config_full);
    heap_release(checkpoint_full);
    if (!valid) SetLastError(ERROR_ACCESS_DENIED);
    return valid;
}

static int write_entry_checkpoint(
    const WCHAR *path,
    const unsigned char nonce[32],
    uint32_t stage,
    DWORD creation
) {
    unsigned char record[ENTRY_CHECKPOINT_BYTES];
    HANDLE file;
    int result;
    memory_zero(record, sizeof(record));
    memory_copy(record, ENTRY_MAGIC, 8);
    write_u32(record + 8, SCHEMA_VERSION);
    write_u32(record + 12, stage);
    memory_copy(record + 16, nonce, 32);
    file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, creation,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    result = write_all(file, record, (DWORD)sizeof(record)) && SetEndOfFile(file)
        && FlushFileBuffers(file);
    if (!CloseHandle(file)) result = 0;
    return result;
}

static int trusted_path_write_denied(const WCHAR *path) {
    HANDLE handle = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        SetLastError(ERROR_ACCESS_DENIED);
        return 0;
    }
    return GetLastError() == ERROR_ACCESS_DENIED;
}

static int access_allowed(
    PSECURITY_DESCRIPTOR descriptor,
    HANDLE token,
    DWORD desired_access,
    int *allowed
) {
    GENERIC_MAPPING mapping;
    PRIVILEGE_SET *privileges = NULL;
    DWORD privileges_length = 0;
    DWORD granted = 0;
    BOOL access = FALSE;
    int result = 0;
    mapping.GenericRead = FILE_GENERIC_READ;
    mapping.GenericWrite = FILE_GENERIC_WRITE;
    mapping.GenericExecute = FILE_GENERIC_EXECUTE;
    mapping.GenericAll = FILE_ALL_ACCESS;
    MapGenericMask(&desired_access, &mapping);
    SetLastError(ERROR_SUCCESS);
    if (AccessCheck(descriptor, token, desired_access, &mapping, NULL, &privileges_length,
        &granted, &access) || GetLastError() != ERROR_INSUFFICIENT_BUFFER
        || privileges_length == 0) goto cleanup;
    privileges = (PRIVILEGE_SET *)heap_array(privileges_length, 1, 1);
    if (privileges == NULL) goto cleanup;
    if (!AccessCheck(descriptor, token, desired_access, &mapping, privileges,
        &privileges_length, &granted, &access)) goto cleanup;
    *allowed = access != FALSE;
    result = 1;
cleanup:
    heap_release(privileges);
    return result;
}

static int bootstrap_access_policy(const WCHAR *path) {
    const SECURITY_INFORMATION information = OWNER_SECURITY_INFORMATION
        | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    HANDLE process_token = NULL;
    HANDLE impersonation_token = NULL;
    DWORD descriptor_length = 0;
    int read_execute_allowed = 0;
    int write_allowed = 0;
    int result = 0;
    if (GetFileSecurityW(path, information, NULL, 0, &descriptor_length)
        || GetLastError() != ERROR_INSUFFICIENT_BUFFER || descriptor_length == 0) goto cleanup;
    descriptor = (PSECURITY_DESCRIPTOR)heap_array(descriptor_length, 1, 1);
    if (descriptor == NULL
        || !GetFileSecurityW(path, information, descriptor, descriptor_length,
            &descriptor_length)
        || !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &process_token)
        || !DuplicateToken(process_token, SecurityImpersonation, &impersonation_token)
        || !access_allowed(descriptor, impersonation_token, GENERIC_READ | GENERIC_EXECUTE,
            &read_execute_allowed)
        || !access_allowed(descriptor, impersonation_token, GENERIC_WRITE, &write_allowed)) {
        goto cleanup;
    }
    result = read_execute_allowed && !write_allowed;
    if (!result) SetLastError(ERROR_ACCESS_DENIED);
cleanup:
    if (impersonation_token != NULL) CloseHandle(impersonation_token);
    if (process_token != NULL) CloseHandle(process_token);
    heap_release(descriptor);
    return result;
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
    memory_zero(timing, sizeof(*timing));
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
    if (!bytes_equal(timing->view, TIMING_MAGIC, 8)
        || !bytes_equal(timing->view + 8, config->nonce, 32)) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    memory_copy(timing->nonce, config->nonce, 32);
    if (!DeleteFileW(config->timing)) return 0;
    return 1;
}

static void close_timing(TimingPage *timing) {
    if (timing->view != NULL) UnmapViewOfFile(timing->view);
    if (timing->mapping != NULL) CloseHandle(timing->mapping);
    if (timing->file != NULL && timing->file != INVALID_HANDLE_VALUE) CloseHandle(timing->file);
    memory_zero(timing, sizeof(*timing));
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
    if (!bytes_equal(timing->view + 8, timing->nonce, 32)) return 0;
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

static SIZE_T quoted_length(const WCHAR *value) {
    SIZE_T length = 2u;
    SIZE_T slashes = 0u;
    const WCHAR *cursor;
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

static WCHAR *append_quoted(WCHAR *output, const WCHAR *value) {
    SIZE_T slashes = 0u;
    const WCHAR *cursor;
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
        } else {
            while (slashes != 0u) {
                *output++ = L'\\';
                --slashes;
            }
            *output++ = *cursor;
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

static WCHAR *product_command_line(const BootstrapConfig *config) {
    SIZE_T total = quoted_length(config->target) + 1u;
    uint32_t index;
    WCHAR *line;
    WCHAR *cursor;
    for (index = 0; index < config->argument_count; ++index) {
        SIZE_T addition = quoted_length(config->arguments[index]) + 1u;
        if (total > SIZE_MAX - addition) return NULL;
        total += addition;
    }
    line = (WCHAR *)heap_array(total, sizeof(WCHAR), 1);
    if (line == NULL) return NULL;
    cursor = append_quoted(line, config->target);
    for (index = 0; index < config->argument_count; ++index) {
        *cursor++ = L' ';
        cursor = append_quoted(cursor, config->arguments[index]);
    }
    *cursor = L'\0';
    return line;
}

typedef struct TokenProof {
    LUID authentication_id;
    int low_integrity;
    int no_enabled_privileges;
    int restricted;
    int restricting_sid_match;
} TokenProof;

typedef struct BrokerSecurity {
    HANDLE primary_token;
    HANDLE restricted_token;
    PSID restricting_sid;
    TokenProof broker;
    TokenProof restricted;
    int se_increase_quota_present;
    int se_increase_quota_enabled;
    int write_restricted_created;
} BrokerSecurity;

typedef struct ProductProof {
    TokenProof token;
    int created_with_create_process_as_user;
    int contained;
    DWORD resume_previous_count;
} ProductProof;

static void *token_information(HANDLE token, TOKEN_INFORMATION_CLASS class_id) {
    DWORD length = 0;
    void *value;
    (void)GetTokenInformation(token, class_id, NULL, 0, &length);
    if (length == 0u) return NULL;
    value = heap_array(length, 1u, 1);
    if (value == NULL) return NULL;
    if (!GetTokenInformation(token, class_id, value, length, &length)) {
        heap_release(value);
        return NULL;
    }
    return value;
}

static int luid_equal(LUID left, LUID right) {
    return left.LowPart == right.LowPart && left.HighPart == right.HighPart;
}

static uint32_t product_proof_flags(
    const BrokerSecurity *security,
    const ProductProof *proof
) {
    uint32_t flags = 0u;
    if (proof->created_with_create_process_as_user) {
        flags |= EXIT_CREATE_PROCESS_AS_USER_SUCCEEDED;
    }
    if (luid_equal(proof->token.authentication_id, security->broker.authentication_id)) {
        flags |= EXIT_PRODUCT_AUTHENTICATION_MATCH;
    }
    if (proof->token.low_integrity) flags |= EXIT_PRODUCT_LOW_INTEGRITY;
    if (security->write_restricted_created && proof->token.restricted) {
        flags |= EXIT_PRODUCT_WRITE_RESTRICTED;
    }
    if (proof->token.no_enabled_privileges) flags |= EXIT_PRODUCT_NO_ENABLED_PRIVILEGES;
    if (proof->token.restricting_sid_match) flags |= EXIT_PRODUCT_RESTRICTING_SID_MATCH;
    return flags;
}

static int token_proof(HANDLE token, PSID expected_sid, TokenProof *proof) {
    TOKEN_STATISTICS *statistics = NULL;
    TOKEN_MANDATORY_LABEL *label = NULL;
    TOKEN_PRIVILEGES *privileges = NULL;
    TOKEN_GROUPS *restricted_sids = NULL;
    DWORD index;
    UCHAR *subauthority_count;
    DWORD *integrity_rid;
    int result = 0;
    memory_zero(proof, sizeof(*proof));
    statistics = (TOKEN_STATISTICS *)token_information(token, TokenStatistics);
    label = (TOKEN_MANDATORY_LABEL *)token_information(token, TokenIntegrityLevel);
    privileges = (TOKEN_PRIVILEGES *)token_information(token, TokenPrivileges);
    restricted_sids = (TOKEN_GROUPS *)token_information(token, TokenRestrictedSids);
    if (statistics == NULL || label == NULL || privileges == NULL || restricted_sids == NULL) {
        goto cleanup;
    }
    proof->authentication_id = statistics->AuthenticationId;
    subauthority_count = GetSidSubAuthorityCount(label->Label.Sid);
    if (subauthority_count == NULL || *subauthority_count == 0u) goto cleanup;
    integrity_rid = GetSidSubAuthority(label->Label.Sid, (DWORD)*subauthority_count - 1u);
    if (integrity_rid == NULL) goto cleanup;
    proof->low_integrity = *integrity_rid == SECURITY_MANDATORY_LOW_RID;
    proof->no_enabled_privileges = 1;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        if ((privileges->Privileges[index].Attributes & SE_PRIVILEGE_ENABLED) != 0u) {
            proof->no_enabled_privileges = 0;
            break;
        }
    }
    proof->restricted = IsTokenRestricted(token) != FALSE;
    proof->restricting_sid_match = expected_sid == NULL ? restricted_sids->GroupCount == 0u : 0;
    if (expected_sid != NULL) {
        for (index = 0; index < restricted_sids->GroupCount; ++index) {
            if (EqualSid(restricted_sids->Groups[index].Sid, expected_sid)) {
                proof->restricting_sid_match = 1;
                break;
            }
        }
    }
    result = 1;
cleanup:
    heap_release(statistics);
    heap_release(label);
    heap_release(privileges);
    heap_release(restricted_sids);
    return result;
}

static int enable_se_increase_quota(
    HANDLE token,
    int *present,
    int *enabled
) {
    TOKEN_PRIVILEGES *privileges = NULL;
    TOKEN_PRIVILEGES requested;
    LUID luid;
    DWORD index;
    int result = 0;
    *present = 0;
    *enabled = 0;
    if (!LookupPrivilegeValueW(NULL, L"SeIncreaseQuotaPrivilege", &luid)) return 0;
    privileges = (TOKEN_PRIVILEGES *)token_information(token, TokenPrivileges);
    if (privileges == NULL) return 0;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        if (luid_equal(privileges->Privileges[index].Luid, luid)) {
            *present = 1;
            break;
        }
    }
    if (!*present) {
        SetLastError(ERROR_PRIVILEGE_NOT_HELD);
        goto cleanup;
    }
    memory_zero(&requested, sizeof(requested));
    requested.PrivilegeCount = 1u;
    requested.Privileges[0].Luid = luid;
    requested.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    SetLastError(ERROR_SUCCESS);
    if (!AdjustTokenPrivileges(token, FALSE, &requested, 0, NULL, NULL)
        || GetLastError() == ERROR_NOT_ALL_ASSIGNED) goto cleanup;
    heap_release(privileges);
    privileges = (TOKEN_PRIVILEGES *)token_information(token, TokenPrivileges);
    if (privileges == NULL) return 0;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        if (luid_equal(privileges->Privileges[index].Luid, luid)
            && (privileges->Privileges[index].Attributes & SE_PRIVILEGE_ENABLED) != 0u) {
            *enabled = 1;
            break;
        }
    }
    if (!*enabled) {
        SetLastError(ERROR_PRIVILEGE_NOT_HELD);
        goto cleanup;
    }
    result = 1;
cleanup:
    heap_release(privileges);
    return result;
}

static int disable_all_privileges(HANDLE token) {
    TOKEN_PRIVILEGES *privileges =
        (TOKEN_PRIVILEGES *)token_information(token, TokenPrivileges);
    DWORD index;
    int result;
    if (privileges == NULL) return 0;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        privileges->Privileges[index].Attributes = 0u;
    }
    SetLastError(ERROR_SUCCESS);
    result = AdjustTokenPrivileges(token, FALSE, privileges, 0, NULL, NULL) != FALSE
        && GetLastError() != ERROR_NOT_ALL_ASSIGNED;
    heap_release(privileges);
    return result;
}

static void close_broker_security(BrokerSecurity *security) {
    if (security->restricted_token != NULL) CloseHandle(security->restricted_token);
    if (security->primary_token != NULL) CloseHandle(security->primary_token);
    if (security->restricting_sid != NULL) LocalFree(security->restricting_sid);
    memory_zero(security, sizeof(*security));
}

static int prepare_broker_security(const BootstrapConfig *config, BrokerSecurity *security) {
    PSID low_sid = NULL;
    SID_AND_ATTRIBUTES restricting;
    TOKEN_MANDATORY_LABEL label;
    DWORD error;
    memory_zero(security, sizeof(*security));
    /* CreateRestrictedToken preserves this handle's rights. Low-integrity labeling needs
       TOKEN_ADJUST_DEFAULT, and CreateProcessAsUser needs TOKEN_ASSIGN_PRIMARY. */
    if (!OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ADJUST_PRIVILEGES | TOKEN_ADJUST_DEFAULT
                | TOKEN_ASSIGN_PRIMARY,
            &security->primary_token)
        || !enable_se_increase_quota(
            security->primary_token,
            &security->se_increase_quota_present,
            &security->se_increase_quota_enabled)
        || !ConvertStringSidToSidA(config->restricting_sid, &security->restricting_sid)
        || !ConvertStringSidToSidW(L"S-1-16-4096", &low_sid)) {
        goto failure;
    }
    memory_zero(&restricting, sizeof(restricting));
    restricting.Sid = security->restricting_sid;
    if (!CreateRestrictedToken(
            security->primary_token,
            DISABLE_MAX_PRIVILEGE | WRITE_RESTRICTED,
            0,
            NULL,
            0,
            NULL,
            1,
            &restricting,
            &security->restricted_token)) {
        goto failure;
    }
    security->write_restricted_created = 1;
    memory_zero(&label, sizeof(label));
    label.Label.Sid = low_sid;
    label.Label.Attributes = SE_GROUP_INTEGRITY;
    if (!SetTokenInformation(
            security->restricted_token,
            TokenIntegrityLevel,
            &label,
            (DWORD)sizeof(label) + GetLengthSid(low_sid))
        || !disable_all_privileges(security->restricted_token)
        || !token_proof(security->primary_token, NULL, &security->broker)
        || !token_proof(
            security->restricted_token,
            security->restricting_sid,
            &security->restricted)
        || !luid_equal(
            security->broker.authentication_id,
            security->restricted.authentication_id)
        || !security->restricted.restricted
        || !security->restricted.low_integrity
        || !security->restricted.no_enabled_privileges
        || !security->restricted.restricting_sid_match) {
        goto failure;
    }
    LocalFree(low_sid);
    return 1;
failure:
    error = GetLastError();
    if (low_sid != NULL) LocalFree(low_sid);
    close_broker_security(security);
    SetLastError(error);
    return 0;
}

static int read_product_handles_adopted(HANDLE input, const unsigned char nonce[32]);

static int create_product(
    const BootstrapConfig *config,
    TimingPage *timing,
    const BrokerSecurity *security,
    DWORD *exit_code,
    ProductProof *proof
) {
    SIZE_T attribute_bytes = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION process;
    HANDLE handles[3];
    WCHAR *command_line = NULL;
    DWORD resume_count;
    HANDLE product_token = NULL;
    unsigned char payload[40];
    uint32_t flags;
    DWORD error;
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
    memory_zero(&startup, sizeof(startup));
    memory_zero(&process, sizeof(process));
    startup.StartupInfo.cb = (DWORD)sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.lpDesktop = config->private_desktop;
    startup.StartupInfo.hStdInput = handles[0];
    startup.StartupInfo.hStdOutput = handles[1];
    startup.StartupInfo.hStdError = handles[2];
    startup.lpAttributeList = attributes;
    if (!record_t0(timing)) goto cleanup;
    if (!CreateProcessAsUserW(security->restricted_token, config->target, command_line, NULL, NULL, TRUE,
        CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, NULL, config->fixture_root,
        &startup.StartupInfo, &process)) goto cleanup;
    proof->created_with_create_process_as_user = 1;
    if (!IsProcessInJob(process.hProcess, config->query_job, &proof->contained)
        || !proof->contained
        || !OpenProcessToken(process.hProcess, TOKEN_QUERY, &product_token)
        || !token_proof(product_token, security->restricting_sid, &proof->token)
        || !luid_equal(proof->token.authentication_id, security->broker.authentication_id)
        || !proof->token.restricted
        || !proof->token.low_integrity
        || !proof->token.no_enabled_privileges
        || !proof->token.restricting_sid_match) {
        if (!proof->contained) SetLastError(ERROR_ACCESS_DENIED);
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        goto process_cleanup;
    }
    resume_count = ResumeThread(process.hThread);
    if (resume_count != 1u) {
        if (resume_count != (DWORD)-1) SetLastError(ERROR_INVALID_PARAMETER);
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        goto process_cleanup;
    }
    proof->resume_previous_count = resume_count;
    flags = product_proof_flags(security, proof);
    write_u32(payload, proof->contained ? 1u : 0u);
    write_u32(payload + 4, proof->token.authentication_id.LowPart);
    write_u32(payload + 8, (uint32_t)proof->token.authentication_id.HighPart);
    write_u32(payload + 12, proof->resume_previous_count);
    write_u32(payload + 16, process.dwProcessId);
    write_u32(payload + 20, process.dwThreadId);
    write_u64(payload + 24, (uint64_t)(uintptr_t)process.hProcess);
    write_u64(payload + 32, (uint64_t)(uintptr_t)process.hThread);
    if (!send_event(config->control_write, config->nonce, EVENT_PRODUCT_STARTED, flags, payload, 40)) {
        error = GetLastError();
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        SetLastError(error);
        goto process_cleanup;
    }
    if (!read_product_handles_adopted(config->control_read, config->nonce)) {
        error = GetLastError();
        TerminateProcess(process.hProcess, 125);
        WaitForSingleObject(process.hProcess, INFINITE);
        SetLastError(error);
        goto process_cleanup;
    }
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, exit_code)) goto process_cleanup;
    result = 1;
process_cleanup:
    if (product_token != NULL) CloseHandle(product_token);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
cleanup:
    heap_release(command_line);
    if (attributes != NULL) {
        if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);
    }
    return result;
}

static int read_arm(HANDLE input, const unsigned char nonce[32]) {
    unsigned char record[48];
    return read_all(input, record, (DWORD)sizeof(record))
        && bytes_equal(record, ARM_MAGIC, 8)
        && read_u32(record + 8) == SCHEMA_VERSION
        && read_u32(record + 12) == (uint32_t)sizeof(record)
        && bytes_equal(record + 16, nonce, 32);
}

static int read_product_handles_adopted(HANDLE input, const unsigned char nonce[32]) {
    unsigned char record[48];
    if (!read_all(input, record, (DWORD)sizeof(record))) return 0;
    if (!bytes_equal(record, PRODUCT_HANDLES_ADOPTED_MAGIC, 8)
        || read_u32(record + 8) != SCHEMA_VERSION
        || read_u32(record + 12) != (uint32_t)sizeof(record)
        || !bytes_equal(record + 16, nonce, 32)) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    return 1;
}

static int decode_nonce(const WCHAR *text, unsigned char nonce[32]) {
    SIZE_T index;
    if (wide_length(text) != 64u) return 0;
    for (index = 0; index < 32u; ++index) {
        WCHAR high = text[index * 2u];
        WCHAR low = text[index * 2u + 1u];
        unsigned int a;
        unsigned int b;
        if (high >= L'0' && high <= L'9') a = (unsigned int)(high - L'0');
        else if (high >= L'a' && high <= L'f') a = (unsigned int)(high - L'a' + 10);
        else if (high >= L'A' && high <= L'F') a = (unsigned int)(high - L'A' + 10);
        else return 0;
        if (low >= L'0' && low <= L'9') b = (unsigned int)(low - L'0');
        else if (low >= L'a' && low <= L'f') b = (unsigned int)(low - L'a' + 10);
        else if (low >= L'A' && low <= L'F') b = (unsigned int)(low - L'A' + 10);
        else return 0;
        nonce[index] = (unsigned char)((a << 4) | b);
    }
    return 1;
}

static void free_entry_checkpoint_identity(EntryCheckpointIdentity *identity) {
    heap_release(identity->checkpoint_path);
    memory_zero(identity, sizeof(*identity));
}

static int consume_entry_checkpoint_environment(EntryCheckpointIdentity *identity) {
    DWORD checkpoint_chars;
    DWORD checkpoint_read;
    WCHAR nonce_text[65];
    DWORD nonce_chars;
    int result = 0;
    memory_zero(identity, sizeof(*identity));
    memory_zero(nonce_text, sizeof(nonce_text));
    checkpoint_chars = GetEnvironmentVariableW(ENTRY_CHECKPOINT_PATH_ENV, NULL, 0);
    if (checkpoint_chars == 0 || checkpoint_chars > MAX_WIDE_CHARS + 1u) goto cleanup;
    identity->checkpoint_path =
        (WCHAR *)heap_array((SIZE_T)checkpoint_chars, sizeof(WCHAR), 1);
    if (identity->checkpoint_path == NULL) goto cleanup;
    checkpoint_read = GetEnvironmentVariableW(
        ENTRY_CHECKPOINT_PATH_ENV, identity->checkpoint_path, checkpoint_chars);
    nonce_chars = GetEnvironmentVariableW(ENTRY_NONCE_ENV, nonce_text, 65u);
    if (checkpoint_read != checkpoint_chars - 1u || nonce_chars != 64u
        || !decode_nonce(nonce_text, identity->nonce)) goto cleanup;
    if (!SetEnvironmentVariableW(ENTRY_CHECKPOINT_PATH_ENV, NULL)
        || !SetEnvironmentVariableW(ENTRY_NONCE_ENV, NULL)) goto cleanup;
    if (!write_entry_checkpoint(identity->checkpoint_path, identity->nonce,
        ENTRY_STAGE_REACHED, CREATE_NEW)) goto cleanup;
    result = 1;
cleanup:
    memory_zero(nonce_text, sizeof(nonce_text));
    if (!result) free_entry_checkpoint_identity(identity);
    return result;
}

static const WCHAR *skip_spaces(const WCHAR *cursor) {
    while (*cursor == L' ' || *cursor == L'\t') ++cursor;
    return cursor;
}

static WCHAR *take_strict_quoted_argument(const WCHAR **cursor) {
    const WCHAR *start;
    SIZE_T length;
    WCHAR *result;
    *cursor = skip_spaces(*cursor);
    if (**cursor != L'"') return NULL;
    start = ++*cursor;
    while (**cursor != L'\0' && **cursor != L'"') ++*cursor;
    if (**cursor != L'"') return NULL;
    length = (SIZE_T)(*cursor - start);
    if (length == 0 || length > MAX_WIDE_CHARS) return NULL;
    result = (WCHAR *)heap_array(length + 1u, sizeof(WCHAR), 1);
    if (result == NULL) return NULL;
    memory_copy(result, start, length * sizeof(WCHAR));
    ++*cursor;
    if (**cursor != L'\0' && **cursor != L' ' && **cursor != L'\t') {
        heap_release(result);
        return NULL;
    }
    return result;
}

static void free_entry_arguments(EntryArguments *arguments) {
    heap_release(arguments->config_path);
    heap_release(arguments->checkpoint_path);
    heap_release(arguments->nonce_text);
    memory_zero(arguments, sizeof(*arguments));
}

static int parse_entry_arguments(EntryArguments *arguments) {
    const WCHAR *cursor = GetCommandLineW();
    WCHAR *program;
    memory_zero(arguments, sizeof(*arguments));
    program = take_strict_quoted_argument(&cursor);
    arguments->config_path = take_strict_quoted_argument(&cursor);
    arguments->checkpoint_path = take_strict_quoted_argument(&cursor);
    arguments->nonce_text = take_strict_quoted_argument(&cursor);
    cursor = skip_spaces(cursor);
    if (program == NULL || arguments->config_path == NULL || arguments->checkpoint_path == NULL
        || arguments->nonce_text == NULL || *cursor != L'\0'
        || !decode_nonce(arguments->nonce_text, arguments->nonce)) {
        heap_release(program);
        free_entry_arguments(arguments);
        SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    heap_release(program);
    return 1;
}

static int bootstrap_run(const EntryArguments *entry) {
    unsigned char *bytes = NULL;
    SIZE_T length = 0;
    BootstrapConfig config;
    WCHAR self_path[MAX_WIDE_CHARS + 1u];
    char observed_bootstrap_sha256[65];
    char observed_target_sha256[65];
    int handles_inheritable = 0;
    int bootstrap_in_job = 0;
    int trusted_denied = 0;
    int bootstrap_write_denied = 0;
    BrokerSecurity security;
    ProductProof product;
    TimingPage timing;
    DWORD exit_code = 125;
    unsigned char payload[256];
    uint32_t flags;
    DWORD query_handle_flags = 0;
    DWORD error;
    uint32_t stage = 0;
    int result = 0;
    memory_zero(&config, sizeof(config));
    memory_zero(&security, sizeof(security));
    memory_zero(&product, sizeof(product));
    memory_zero(&timing, sizeof(timing));
    if (!write_entry_checkpoint(entry->checkpoint_path, entry->nonce,
        ENTRY_STAGE_CONFIG_READ_STARTED, OPEN_EXISTING)) return 125;
    bytes = read_config_file(entry->config_path, &length);
    if (bytes == NULL || !parse_config(bytes, length, &config)) {
        heap_release(bytes);
        return 125;
    }
    heap_release(bytes);
    if (!bytes_equal(config.nonce, entry->nonce, 32)
        || !validate_paths(entry->config_path, entry->checkpoint_path, &config)
        || !DeleteFileW(entry->config_path)
        || !write_entry_checkpoint(entry->checkpoint_path, entry->nonce,
            ENTRY_STAGE_CONFIG_CONSUMED, OPEN_EXISTING)) goto failure;
    if (!send_stage(config.control_write, config.nonce, STAGE_NATIVE_ENTRY_REACHED)
        || !send_stage(config.control_write, config.nonce, STAGE_NATIVE_CONFIG_READ_STARTED)) {
        goto failure;
    }
    stage = STAGE_CONFIG_CONSUMED;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    if (GetModuleFileNameW(NULL, self_path, MAX_WIDE_CHARS + 1u) == 0
        || !hash_file(self_path, observed_bootstrap_sha256)
        || !hash_text_equal(observed_bootstrap_sha256, config.bootstrap_sha256)
        || !hash_file(config.target, observed_target_sha256)
        || !hash_text_equal(observed_target_sha256, config.target_sha256)) goto failure;
    trusted_denied = trusted_path_write_denied(config.trusted_probe);
    bootstrap_write_denied = bootstrap_access_policy(self_path);
    if (!trusted_denied || !bootstrap_write_denied) goto failure;
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
    stage = STAGE_RESTRICTED_PRODUCT_TOKEN_READY;
    if (!prepare_broker_security(&config, &security)) goto failure;
    if (!send_stage(config.control_write, config.nonce, stage)) goto failure;
    flags = READY_CONFIG_CONSUMED | READY_HANDLES_VALID | READY_HANDLES_INHERITABLE
        | READY_PRIVATE_JOB_MEMBER | READY_TRUSTED_PATH_DENIED | READY_BOOTSTRAP_WRITE_DENIED;
    if (security.se_increase_quota_present) flags |= READY_SE_INCREASE_QUOTA_PRESENT;
    if (security.se_increase_quota_enabled) flags |= READY_SE_INCREASE_QUOTA_ENABLED;
    if (security.restricted.restricted) flags |= READY_RESTRICTED_TOKEN;
    if (security.restricted.low_integrity) flags |= READY_RESTRICTED_LOW_INTEGRITY;
    if (security.restricted.no_enabled_privileges) {
        flags |= READY_RESTRICTED_NO_ENABLED_PRIVILEGES;
    }
    if (luid_equal(security.broker.authentication_id, security.restricted.authentication_id)) {
        flags |= READY_RESTRICTED_AUTHENTICATION_MATCH;
    }
    if (security.restricted.restricting_sid_match) flags |= READY_RESTRICTING_SID_MATCH;
    if (security.write_restricted_created) flags |= READY_WRITE_RESTRICTED_CREATED;
    {
        SIZE_T index;
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
    write_u32(payload + 32, security.broker.authentication_id.LowPart);
    write_u32(payload + 36, (uint32_t)security.broker.authentication_id.HighPart);
    write_u32(payload + 40, security.restricted.authentication_id.LowPart);
    write_u32(payload + 44, (uint32_t)security.restricted.authentication_id.HighPart);
    {
        SIZE_T sid_length = 0;
        while (sid_length <= MAX_RESTRICTING_SID_BYTES
            && config.restricting_sid[sid_length] != '\0') ++sid_length;
        if (sid_length == 0u || sid_length > MAX_RESTRICTING_SID_BYTES) goto failure;
        write_u32(payload + 48, (uint32_t)sid_length);
        memory_copy(payload + 52, config.restricting_sid, sid_length);
        if (!send_event(config.control_write, config.nonce, EVENT_READY, flags,
            payload, (uint32_t)(52u + sid_length))) goto failure;
    }
    if (!read_arm(config.control_read, config.nonce)) goto failure;
    if (!create_product(&config, &timing, &security, &exit_code, &product)) goto failure;
    flags = product_proof_flags(&security, &product);
    write_u32(payload, exit_code);
    write_u32(payload + 4, product.contained ? 1u : 0u);
    write_u32(payload + 8, product.token.authentication_id.LowPart);
    write_u32(payload + 12, (uint32_t)product.token.authentication_id.HighPart);
    if (!send_event(config.control_write, config.nonce, EVENT_EXIT, flags, payload, 16)) goto failure;
    result = (int)exit_code;
    goto cleanup;
failure:
    error = GetLastError();
    send_error(config.control_write, config.nonce, error, stage);
    result = 125;
cleanup:
    close_broker_security(&security);
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

static int bootstrap_entry_inner(void) {
    EntryCheckpointIdentity identity;
    EntryArguments arguments;
    int result;
    if (!consume_entry_checkpoint_environment(&identity)) return 125;
    if (!parse_entry_arguments(&arguments)) {
        free_entry_checkpoint_identity(&identity);
        return 125;
    }
    if (!wide_equal_ignore_case(identity.checkpoint_path, arguments.checkpoint_path)
        || !bytes_equal(identity.nonce, arguments.nonce, sizeof(identity.nonce))) {
        SetLastError(ERROR_ACCESS_DENIED);
        result = 125;
    } else {
        result = bootstrap_run(&arguments);
    }
    free_entry_arguments(&arguments);
    free_entry_checkpoint_identity(&identity);
    return result;
}

__declspec(safebuffers) void WINAPI bootstrap_entry(void) {
    /* The custom entry cannot check a cookie before the process initializes it. */
    __security_init_cookie();
    ExitProcess((UINT)bootstrap_entry_inner());
}
