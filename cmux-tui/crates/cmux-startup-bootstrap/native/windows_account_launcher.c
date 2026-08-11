#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <bcrypt.h>
#include <intrin.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")

#define BOOTSTRAP_SCHEMA_VERSION 8u
#define LAUNCHER_SCHEMA_VERSION 2u
#define MAX_CONFIG_BYTES (64u * 1024u)
#define MAX_WIDE_CHARS 32767u
#define CONFIG_HEADER_BYTES 144u
#define CONFIG_FIELD_COUNT 7u
#define RECORD_HEADER_BYTES 56u
#define EVENT_LAUNCHER_READY 6u
#define EVENT_LAUNCHER_EXIT 7u
#define EVENT_LAUNCHER_ERROR 8u
#define EVENT_LAUNCHER_RESUMED 9u
#define LAUNCHER_STAGE_MARKER 0x4c4e4348u
#define BOOTSTRAP_STAGE_MARKER 0x42535450u
#define JOB_UI_RESTRICTION_MASK 0xffu
#define LAUNCHER_READY_CONFIG_CONSUMED (1u << 0)
#define LAUNCHER_READY_SELF_HASH_MATCH (1u << 1)
#define LAUNCHER_READY_BOOTSTRAP_HASH_MATCH (1u << 2)
#define LAUNCHER_READY_HANDLES_EXACT (1u << 3)
#define LAUNCHER_READY_HANDLE_INHERITANCE_EXACT (1u << 4)
#define LAUNCHER_READY_JOB_MEMBER (1u << 5)
#define LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH (1u << 6)
#define LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT (1u << 7)
#define LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED (1u << 8)
#define LAUNCHER_READY_SESSION_MATCH (1u << 9)
#define LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED (1u << 10)
#define LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER (1u << 11)
#define LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH (1u << 12)
#define LAUNCHER_READY_EMPTY_DESKTOP_SELECTION (1u << 13)
#define LAUNCHER_READY_CREATE_NO_WINDOW (1u << 14)
#define LAUNCHER_READY_HANDLE_LIST_EXACT (1u << 15)
#define LAUNCHER_READY_SUPERVISOR_TARGET_EXACT (1u << 16)
#define LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED (1u << 17)
#define LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED (1u << 0)
#define STAGE_CONFIG 1u
#define STAGE_PRIVILEGE 2u
#define STAGE_BOOTSTRAP_CREATE 3u
#define STAGE_READY 4u
#define STAGE_WAIT 5u

static const unsigned char CONFIG_MAGIC[8] = {'C','M','U','X','L','0','0','1'};
static const unsigned char EVENT_MAGIC[8] = {'C','M','U','X','E','0','0','1'};
static const unsigned char ADOPTED_MAGIC[8] = {'C','M','U','X','J','0','0','1'};
static const WCHAR ENTRY_CHECKPOINT_PREFIX[] =
    L"CMUX_BENCH_BOOTSTRAP_ENTRY_CHECKPOINT=";
static const WCHAR ENTRY_NONCE_PREFIX[] = L"CMUX_BENCH_BOOTSTRAP_ENTRY_NONCE=";

void __cdecl __security_init_cookie(void);

typedef struct BufferCursor {
    const unsigned char *bytes;
    SIZE_T length;
    SIZE_T offset;
} BufferCursor;

typedef struct LauncherConfig {
    unsigned char nonce[32];
    HANDLE control_read;
    HANDLE control_write;
    HANDLE standard_handles[3];
    HANDLE query_job;
    HANDLE launcher_gate;
    HANDLE supervisor_process;
    DWORD account_session_id;
    DWORD job_ui_restriction_mask;
    DWORD supervisor_process_id;
    WCHAR *launcher;
    char launcher_sha256[65];
    WCHAR *bootstrap;
    char bootstrap_sha256[65];
    WCHAR *bootstrap_config;
    char bootstrap_config_sha256[65];
    WCHAR *bootstrap_entry_checkpoint;
} LauncherConfig;

typedef struct EntryArguments {
    WCHAR *config_path;
    WCHAR *nonce_text;
    unsigned char nonce[32];
} EntryArguments;

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

static int wide_equal_ignore_case(const WCHAR *left, const WCHAR *right) {
    return CompareStringOrdinal(left, -1, right, -1, TRUE) == CSTR_EQUAL;
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

static int read_adoption_ack(HANDLE input, const unsigned char nonce[32]) {
    unsigned char record[48];
    if (!read_all(input, record, (DWORD)sizeof(record))) return 0;
    if (!bytes_equal(record, ADOPTED_MAGIC, 8)
        || read_u32(record + 8) != BOOTSTRAP_SCHEMA_VERSION
        || read_u32(record + 12) != (uint32_t)sizeof(record)
        || !bytes_equal(record + 16, nonce, 32)) {
        SetLastError(ERROR_INVALID_DATA);
        return 0;
    }
    return 1;
}

static void close_remote_handle(HANDLE target_process, HANDLE remote_handle) {
    HANDLE local = NULL;
    if (remote_handle != NULL
        && DuplicateHandle(target_process, remote_handle, GetCurrentProcess(), &local, 0, FALSE,
            DUPLICATE_SAME_ACCESS | DUPLICATE_CLOSE_SOURCE)) {
        CloseHandle(local);
    }
}

static int duplicate_bootstrap_handles(
    HANDLE supervisor_process,
    HANDLE bootstrap_process,
    HANDLE bootstrap_thread,
    HANDLE *remote_process,
    HANDLE *remote_thread
) {
    DWORD error;
    *remote_process = NULL;
    *remote_thread = NULL;
    if (!DuplicateHandle(GetCurrentProcess(), bootstrap_process, supervisor_process,
            remote_process, 0, FALSE, DUPLICATE_SAME_ACCESS)) return 0;
    if (!DuplicateHandle(GetCurrentProcess(), bootstrap_thread, supervisor_process,
            remote_thread, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        error = GetLastError();
        close_remote_handle(supervisor_process, *remote_process);
        *remote_process = NULL;
        SetLastError(error);
        return 0;
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
    unsigned char record[RECORD_HEADER_BYTES + 96u];
    uint32_t total = RECORD_HEADER_BYTES + payload_length;
    if (payload_length > 96u) {
        SetLastError(ERROR_BUFFER_OVERFLOW);
        return 0;
    }
    memory_zero(record, sizeof(record));
    memory_copy(record, EVENT_MAGIC, 8);
    write_u32(record + 8, BOOTSTRAP_SCHEMA_VERSION);
    write_u32(record + 12, total);
    write_u32(record + 16, type);
    write_u32(record + 20, flags);
    memory_copy(record + 24, nonce, 32);
    if (payload_length != 0u) memory_copy(record + RECORD_HEADER_BYTES, payload, payload_length);
    return write_all(output, record, total);
}

static void send_error(HANDLE output, const unsigned char nonce[32], DWORD error, DWORD stage) {
    unsigned char payload[8];
    write_u32(payload, error == ERROR_SUCCESS ? ERROR_INVALID_DATA : error);
    write_u32(payload + 4, stage);
    (void)send_event(output, nonce, EVENT_LAUNCHER_ERROR, 0, payload, sizeof(payload));
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

static void free_config(LauncherConfig *config) {
    heap_release(config->launcher);
    heap_release(config->bootstrap);
    heap_release(config->bootstrap_config);
    heap_release(config->bootstrap_entry_checkpoint);
    memory_zero(config, sizeof(*config));
}

static int handles_exact_and_distinct(const LauncherConfig *config, int *inheritance_exact) {
    HANDLE handles[8];
    unsigned int index;
    unsigned int other;
    handles[0] = config->control_read;
    handles[1] = config->control_write;
    handles[2] = config->standard_handles[0];
    handles[3] = config->standard_handles[1];
    handles[4] = config->standard_handles[2];
    handles[5] = config->query_job;
    handles[6] = config->launcher_gate;
    handles[7] = config->supervisor_process;
    *inheritance_exact = 1;
    for (index = 0; index < 8u; ++index) {
        DWORD flags = 0;
        if (handles[index] == NULL || !GetHandleInformation(handles[index], &flags)) return 0;
        if (((flags & HANDLE_FLAG_INHERIT) != 0u) != (index < 7u)) *inheritance_exact = 0;
        for (other = 0; other < index; ++other) {
            if (handles[index] == handles[other]) {
                SetLastError(ERROR_INVALID_HANDLE);
                return 0;
            }
        }
    }
    for (index = 0; index < 3u; ++index) {
        SetLastError(ERROR_SUCCESS);
        if (GetFileType(config->standard_handles[index]) == FILE_TYPE_UNKNOWN
            && GetLastError() != ERROR_SUCCESS) return 0;
    }
    return 1;
}

static int parse_config(const unsigned char *bytes, SIZE_T length, LauncherConfig *config) {
    BufferCursor cursor;
    uint32_t index;
    HANDLE handles[8];
    if (length < CONFIG_HEADER_BYTES || length > MAX_CONFIG_BYTES
        || !bytes_equal(bytes, CONFIG_MAGIC, 8)
        || read_u32(bytes + 8) != LAUNCHER_SCHEMA_VERSION
        || read_u32(bytes + 12) != (uint32_t)length
        || read_u32(bytes + 16) != CONFIG_FIELD_COUNT
        || read_u32(bytes + 20) != LAUNCHER_STAGE_MARKER
        || read_u32(bytes + 24) != BOOTSTRAP_STAGE_MARKER
        || read_u32(bytes + 28) != 0u) return 0;
    memory_zero(config, sizeof(*config));
    memory_copy(config->nonce, bytes + 32, 32);
    for (index = 0; index < 8u; ++index) {
        handles[index] = (HANDLE)(uintptr_t)read_u64(bytes + 64u + index * 8u);
        if (handles[index] == NULL) return 0;
    }
    for (index = 0; index < 8u; ++index) {
        uint32_t other;
        for (other = 0; other < index; ++other) {
            if (handles[index] == handles[other]) return 0;
        }
    }
    config->control_read = handles[0];
    config->control_write = handles[1];
    config->standard_handles[0] = handles[2];
    config->standard_handles[1] = handles[3];
    config->standard_handles[2] = handles[4];
    config->query_job = handles[5];
    config->launcher_gate = handles[6];
    config->supervisor_process = handles[7];
    config->account_session_id = read_u32(bytes + 128);
    config->job_ui_restriction_mask = read_u32(bytes + 132);
    config->supervisor_process_id = read_u32(bytes + 136);
    if (config->job_ui_restriction_mask != JOB_UI_RESTRICTION_MASK
        || config->supervisor_process_id == 0u || read_u32(bytes + 140) != 0u) return 0;
    cursor.bytes = bytes;
    cursor.length = length;
    cursor.offset = CONFIG_HEADER_BYTES;
    config->launcher = take_utf16(&cursor);
    if (config->launcher == NULL || !take_hash(&cursor, config->launcher_sha256)) goto failure;
    config->bootstrap = take_utf16(&cursor);
    if (config->bootstrap == NULL || !take_hash(&cursor, config->bootstrap_sha256)) goto failure;
    config->bootstrap_config = take_utf16(&cursor);
    if (config->bootstrap_config == NULL
        || !take_hash(&cursor, config->bootstrap_config_sha256)) goto failure;
    config->bootstrap_entry_checkpoint = take_utf16(&cursor);
    if (config->bootstrap_entry_checkpoint == NULL || cursor.offset != cursor.length
        || wide_equal_ignore_case(config->launcher, config->bootstrap)) goto failure;
    return 1;
failure:
    free_config(config);
    return 0;
}

static unsigned char *read_config_file(const WCHAR *path, SIZE_T *length_out) {
    HANDLE file = CreateFileW(path, GENERIC_READ, 0, NULL, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    LARGE_INTEGER size;
    unsigned char *bytes;
    DWORD count;
    if (file == INVALID_HANDLE_VALUE) return NULL;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < CONFIG_HEADER_BYTES
        || size.QuadPart > MAX_CONFIG_BYTES) {
        CloseHandle(file);
        return NULL;
    }
    bytes = (unsigned char *)heap_array((SIZE_T)size.QuadPart, 1, 0);
    if (bytes == NULL) {
        CloseHandle(file);
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

static void hex_bytes(const unsigned char *bytes, SIZE_T length, char *output) {
    static const char HEX[] = "0123456789abcdef";
    SIZE_T index;
    for (index = 0; index < length; ++index) {
        output[index * 2u] = HEX[bytes[index] >> 4];
        output[index * 2u + 1u] = HEX[bytes[index] & 0x0f];
    }
    output[length * 2u] = '\0';
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

static int hash_to_bytes(const char hash[65], unsigned char output[32]) {
    SIZE_T index;
    for (index = 0; index < 32u; ++index) {
        unsigned char high = ascii_lower((unsigned char)hash[index * 2u]);
        unsigned char low = ascii_lower((unsigned char)hash[index * 2u + 1u]);
        unsigned int a = high <= '9' ? high - '0' : high - 'a' + 10u;
        unsigned int b = low <= '9' ? low - '0' : low - 'a' + 10u;
        if (a > 15u || b > 15u) return 0;
        output[index] = (unsigned char)((a << 4) | b);
    }
    return 1;
}

static int token_session_id(HANDLE token, DWORD *session_id) {
    DWORD returned = 0;
    return GetTokenInformation(token, TokenSessionId, session_id, sizeof(*session_id), &returned)
        && returned == sizeof(*session_id);
}

static int enable_increase_quota(HANDLE token, int *present, int *enabled) {
    DWORD bytes = 0;
    TOKEN_PRIVILEGES *privileges = NULL;
    TOKEN_PRIVILEGES requested;
    LUID luid;
    DWORD index;
    int result = 0;
    *present = 0;
    *enabled = 0;
    if (!LookupPrivilegeValueW(NULL, L"SeIncreaseQuotaPrivilege", &luid)) return 0;
    (void)GetTokenInformation(token, TokenPrivileges, NULL, 0, &bytes);
    if (bytes < sizeof(TOKEN_PRIVILEGES)) return 0;
    privileges = (TOKEN_PRIVILEGES *)heap_array(bytes, 1, 1);
    if (privileges == NULL
        || !GetTokenInformation(token, TokenPrivileges, privileges, bytes, &bytes)) goto cleanup;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        if (privileges->Privileges[index].Luid.LowPart == luid.LowPart
            && privileges->Privileges[index].Luid.HighPart == luid.HighPart) {
            *present = 1;
            break;
        }
    }
    if (!*present) {
        SetLastError(ERROR_PRIVILEGE_NOT_HELD);
        goto cleanup;
    }
    memory_zero(&requested, sizeof(requested));
    requested.PrivilegeCount = 1;
    requested.Privileges[0].Luid = luid;
    requested.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    SetLastError(ERROR_SUCCESS);
    if (!AdjustTokenPrivileges(token, FALSE, &requested, 0, NULL, NULL)
        || GetLastError() == ERROR_NOT_ALL_ASSIGNED) goto cleanup;
    heap_release(privileges);
    privileges = NULL;
    bytes = 0;
    (void)GetTokenInformation(token, TokenPrivileges, NULL, 0, &bytes);
    privileges = (TOKEN_PRIVILEGES *)heap_array(bytes, 1, 1);
    if (privileges == NULL
        || !GetTokenInformation(token, TokenPrivileges, privileges, bytes, &bytes)) goto cleanup;
    for (index = 0; index < privileges->PrivilegeCount; ++index) {
        if (privileges->Privileges[index].Luid.LowPart == luid.LowPart
            && privileges->Privileges[index].Luid.HighPart == luid.HighPart
            && (privileges->Privileges[index].Attributes & SE_PRIVILEGE_ENABLED) != 0u) {
            *enabled = 1;
            break;
        }
    }
    result = *enabled;
cleanup:
    heap_release(privileges);
    return result;
}

static int query_job_ui_restrictions(HANDLE job, DWORD expected) {
    JOBOBJECT_BASIC_UI_RESTRICTIONS restrictions;
    DWORD returned = 0;
    memory_zero(&restrictions, sizeof(restrictions));
    return QueryInformationJobObject(job, JobObjectBasicUIRestrictions,
        &restrictions, sizeof(restrictions), &returned)
        && returned == sizeof(restrictions)
        && restrictions.UIRestrictionsClass == expected;
}

static SIZE_T quoted_length(const WCHAR *value) {
    SIZE_T total = 2u;
    SIZE_T slashes = 0u;
    const WCHAR *cursor;
    for (cursor = value; *cursor != L'\0'; ++cursor) {
        if (*cursor == L'\\') {
            ++slashes;
        } else if (*cursor == L'"') {
            total += slashes + 2u;
            slashes = 0u;
        } else {
            total += slashes + 1u;
            slashes = 0u;
        }
    }
    return total + slashes * 2u;
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

static void nonce_text(const unsigned char nonce[32], WCHAR output[65]) {
    static const WCHAR HEX[] = L"0123456789abcdef";
    SIZE_T index;
    for (index = 0; index < 32u; ++index) {
        output[index * 2u] = HEX[nonce[index] >> 4];
        output[index * 2u + 1u] = HEX[nonce[index] & 0x0fu];
    }
    output[64] = L'\0';
}

static WCHAR *bootstrap_command_line(const LauncherConfig *config) {
    WCHAR nonce[65];
    SIZE_T total;
    WCHAR *line;
    WCHAR *cursor;
    nonce_text(config->nonce, nonce);
    total = quoted_length(config->bootstrap) + quoted_length(config->bootstrap_config)
        + quoted_length(config->bootstrap_entry_checkpoint) + quoted_length(nonce) + 4u;
    line = (WCHAR *)heap_array(total, sizeof(WCHAR), 1);
    if (line == NULL) return NULL;
    cursor = append_quoted(line, config->bootstrap);
    *cursor++ = L' ';
    cursor = append_quoted(cursor, config->bootstrap_config);
    *cursor++ = L' ';
    cursor = append_quoted(cursor, config->bootstrap_entry_checkpoint);
    *cursor++ = L' ';
    cursor = append_quoted(cursor, nonce);
    *cursor = L'\0';
    return line;
}

static WCHAR *bootstrap_environment(const LauncherConfig *config) {
    WCHAR nonce[65];
    SIZE_T checkpoint_prefix = (sizeof(ENTRY_CHECKPOINT_PREFIX) / sizeof(WCHAR)) - 1u;
    SIZE_T nonce_prefix = (sizeof(ENTRY_NONCE_PREFIX) / sizeof(WCHAR)) - 1u;
    SIZE_T checkpoint_length = wide_length(config->bootstrap_entry_checkpoint);
    SIZE_T total;
    WCHAR *block;
    WCHAR *cursor;
    if (checkpoint_length == SIZE_MAX) return NULL;
    nonce_text(config->nonce, nonce);
    total = checkpoint_prefix + checkpoint_length + 1u + nonce_prefix + 64u + 2u;
    block = (WCHAR *)heap_array(total, sizeof(WCHAR), 1);
    if (block == NULL) return NULL;
    cursor = block;
    memory_copy(cursor, ENTRY_CHECKPOINT_PREFIX, checkpoint_prefix * sizeof(WCHAR));
    cursor += checkpoint_prefix;
    memory_copy(cursor, config->bootstrap_entry_checkpoint, checkpoint_length * sizeof(WCHAR));
    cursor += checkpoint_length + 1u;
    memory_copy(cursor, ENTRY_NONCE_PREFIX, nonce_prefix * sizeof(WCHAR));
    cursor += nonce_prefix;
    memory_copy(cursor, nonce, 64u * sizeof(WCHAR));
    cursor += 65u;
    *cursor = L'\0';
    return block;
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

static const WCHAR *skip_spaces(const WCHAR *cursor) {
    while (*cursor == L' ' || *cursor == L'\t') ++cursor;
    return cursor;
}

static WCHAR *take_quoted_argument(const WCHAR **cursor) {
    const WCHAR *start;
    SIZE_T length;
    WCHAR *result;
    *cursor = skip_spaces(*cursor);
    if (**cursor != L'"') return NULL;
    start = ++*cursor;
    while (**cursor != L'\0' && **cursor != L'"') ++*cursor;
    if (**cursor != L'"') return NULL;
    length = (SIZE_T)(*cursor - start);
    if (length == 0u || length > MAX_WIDE_CHARS) return NULL;
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
    heap_release(arguments->nonce_text);
    memory_zero(arguments, sizeof(*arguments));
}

static int parse_entry_arguments(EntryArguments *arguments) {
    const WCHAR *cursor = GetCommandLineW();
    WCHAR *program;
    memory_zero(arguments, sizeof(*arguments));
    program = take_quoted_argument(&cursor);
    arguments->config_path = take_quoted_argument(&cursor);
    arguments->nonce_text = take_quoted_argument(&cursor);
    cursor = skip_spaces(cursor);
    if (program == NULL || arguments->config_path == NULL || arguments->nonce_text == NULL
        || *cursor != L'\0' || !decode_nonce(arguments->nonce_text, arguments->nonce)) {
        heap_release(program);
        free_entry_arguments(arguments);
        SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    heap_release(program);
    return 1;
}

static int launcher_run(const EntryArguments *entry) {
    unsigned char *bytes = NULL;
    SIZE_T length = 0;
    LauncherConfig config;
    WCHAR self_path[MAX_WIDE_CHARS + 1u];
    char self_hash[65];
    char bootstrap_hash[65];
    char bootstrap_config_hash[65];
    HANDLE privilege_token = NULL;
    HANDLE launch_token = NULL;
    HANDLE bootstrap_token = NULL;
    DWORD launcher_session = 0;
    DWORD bootstrap_session = 0;
    int privilege_present = 0;
    int privilege_enabled = 0;
    int handle_inheritance_exact = 0;
    int launcher_in_job = 0;
    int bootstrap_in_job = 0;
    SIZE_T attribute_bytes = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    int attributes_initialized = 0;
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION process;
    HANDLE remote_process = NULL;
    HANDLE remote_thread = NULL;
    int remote_handles_transferred = 0;
    HANDLE handles[7];
    WCHAR empty_desktop[1] = {L'\0'};
    WCHAR *command_line = NULL;
    WCHAR *environment = NULL;
    DWORD creation_flags = CREATE_NO_WINDOW | CREATE_SUSPENDED
        | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
    DWORD resume_count = (DWORD)-1;
    DWORD bootstrap_exit = 125u;
    unsigned char payload[112];
    uint32_t flags = 0u;
    DWORD stage = STAGE_CONFIG;
    DWORD error = ERROR_SUCCESS;
    int result = 125;
    memory_zero(&config, sizeof(config));
    memory_zero(&startup, sizeof(startup));
    memory_zero(&process, sizeof(process));
    bytes = read_config_file(entry->config_path, &length);
    if (bytes == NULL || !parse_config(bytes, length, &config)
        || !bytes_equal(entry->nonce, config.nonce, 32)
        || !DeleteFileW(entry->config_path)) goto failure;
    heap_release(bytes);
    bytes = NULL;
    if (GetModuleFileNameW(NULL, self_path, MAX_WIDE_CHARS + 1u) == 0
        || !wide_equal_ignore_case(self_path, config.launcher)
        || !hash_file(self_path, self_hash)
        || !hash_text_equal(self_hash, config.launcher_sha256)
        || !hash_file(config.bootstrap, bootstrap_hash)
        || !hash_text_equal(bootstrap_hash, config.bootstrap_sha256)
        || hash_text_equal(self_hash, bootstrap_hash)
        || !hash_file(config.bootstrap_config, bootstrap_config_hash)
        || !hash_text_equal(bootstrap_config_hash, config.bootstrap_config_sha256)
        || !handles_exact_and_distinct(&config, &handle_inheritance_exact)
        || !handle_inheritance_exact
        || !IsProcessInJob(GetCurrentProcess(), config.query_job, &launcher_in_job)
        || !launcher_in_job
        || !query_job_ui_restrictions(config.query_job, config.job_ui_restriction_mask)) {
        goto failure;
    }
    stage = STAGE_PRIVILEGE;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
            &privilege_token)
        || !enable_increase_quota(
            privilege_token, &privilege_present, &privilege_enabled)
        || !token_session_id(privilege_token, &launcher_session)
        || launcher_session != config.account_session_id
        || !OpenProcessToken(GetCurrentProcess(),
            TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_DEFAULT,
            &launch_token)) {
        goto failure;
    }
    stage = STAGE_BOOTSTRAP_CREATE;
    handles[0] = config.control_read;
    handles[1] = config.control_write;
    handles[2] = config.standard_handles[0];
    handles[3] = config.standard_handles[1];
    handles[4] = config.standard_handles[2];
    handles[5] = config.query_job;
    handles[6] = config.launcher_gate;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
    attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_bytes);
    if (attributes == NULL
        || !InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes)) goto failure;
    attributes_initialized = 1;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            handles, sizeof(handles), NULL, NULL)) goto failure;
    command_line = bootstrap_command_line(&config);
    environment = bootstrap_environment(&config);
    if (command_line == NULL || environment == NULL) goto failure;
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = config.standard_handles[0];
    startup.StartupInfo.hStdOutput = config.standard_handles[1];
    startup.StartupInfo.hStdError = config.standard_handles[2];
    startup.StartupInfo.lpDesktop = empty_desktop;
    startup.lpAttributeList = attributes;
    if (!CreateProcessAsUserW(launch_token, config.bootstrap, command_line, NULL, NULL, TRUE,
            creation_flags, environment, NULL, &startup.StartupInfo, &process)
        || !IsProcessInJob(process.hProcess, config.query_job, &bootstrap_in_job)
        || !bootstrap_in_job
        || !OpenProcessToken(process.hProcess, TOKEN_QUERY, &bootstrap_token)
        || !token_session_id(bootstrap_token, &bootstrap_session)
        || bootstrap_session != config.account_session_id
        || !duplicate_bootstrap_handles(config.supervisor_process, process.hProcess,
            process.hThread, &remote_process, &remote_thread)) {
        goto failure;
    }
    stage = STAGE_READY;
    flags = LAUNCHER_READY_CONFIG_CONSUMED
        | LAUNCHER_READY_SELF_HASH_MATCH
        | LAUNCHER_READY_BOOTSTRAP_HASH_MATCH
        | LAUNCHER_READY_HANDLES_EXACT
        | LAUNCHER_READY_HANDLE_INHERITANCE_EXACT
        | LAUNCHER_READY_JOB_MEMBER
        | LAUNCHER_READY_JOB_UI_RESTRICTIONS_MATCH
        | LAUNCHER_READY_SE_INCREASE_QUOTA_PRESENT
        | LAUNCHER_READY_SE_INCREASE_QUOTA_ENABLED
        | LAUNCHER_READY_SESSION_MATCH
        | LAUNCHER_READY_BOOTSTRAP_CREATED_SUSPENDED
        | LAUNCHER_READY_BOOTSTRAP_JOB_MEMBER
        | LAUNCHER_READY_BOOTSTRAP_SESSION_MATCH
        | LAUNCHER_READY_EMPTY_DESKTOP_SELECTION
        | LAUNCHER_READY_CREATE_NO_WINDOW
        | LAUNCHER_READY_HANDLE_LIST_EXACT
        | LAUNCHER_READY_SUPERVISOR_TARGET_EXACT
        | LAUNCHER_READY_BOOTSTRAP_HANDLES_DUPLICATED;
    if (!hash_to_bytes(self_hash, payload)
        || !hash_to_bytes(bootstrap_hash, payload + 32)) goto failure;
    write_u32(payload + 64, config.account_session_id);
    write_u32(payload + 68, launcher_session);
    write_u32(payload + 72, bootstrap_session);
    write_u32(payload + 76, config.job_ui_restriction_mask);
    write_u32(payload + 80, process.dwProcessId);
    write_u32(payload + 84, process.dwThreadId);
    write_u32(payload + 88, config.supervisor_process_id);
    write_u32(payload + 92, GetCurrentProcessId());
    write_u64(payload + 96, (uint64_t)(uintptr_t)remote_process);
    write_u64(payload + 104, (uint64_t)(uintptr_t)remote_thread);
    if (!send_event(config.control_write, config.nonce, EVENT_LAUNCHER_READY,
            flags, payload, sizeof(payload))) goto failure;
    remote_handles_transferred = 1;
    if (!read_adoption_ack(config.control_read, config.nonce)) goto failure;
    resume_count = ResumeThread(process.hThread);
    if (resume_count != 1u) {
        if (resume_count != (DWORD)-1) SetLastError(ERROR_INVALID_PARAMETER);
        goto failure;
    }
    write_u32(payload, resume_count);
    write_u32(payload + 4, process.dwProcessId);
    if (!send_event(config.control_write, config.nonce, EVENT_LAUNCHER_RESUMED,
            LAUNCHER_RESUMED_ADOPTION_ACKNOWLEDGED, payload, 8u)
        || !SetEvent(config.launcher_gate)) goto failure;
    stage = STAGE_WAIT;
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, &bootstrap_exit)) goto failure;
    write_u32(payload, bootstrap_exit);
    write_u32(payload + 4, resume_count);
    write_u32(payload + 8, process.dwProcessId);
    if (!send_event(config.control_write, config.nonce, EVENT_LAUNCHER_EXIT,
            0, payload, 12u)) goto failure;
    result = (int)bootstrap_exit;
    goto cleanup;
failure:
    error = GetLastError();
    if (!remote_handles_transferred) {
        close_remote_handle(config.supervisor_process, remote_thread);
        close_remote_handle(config.supervisor_process, remote_process);
        remote_thread = NULL;
        remote_process = NULL;
    }
    send_error(config.control_write, config.nonce, error, stage);
    if (process.hProcess != NULL) {
        (void)TerminateProcess(process.hProcess, 125u);
        (void)WaitForSingleObject(process.hProcess, INFINITE);
    }
cleanup:
    if (bootstrap_token != NULL) CloseHandle(bootstrap_token);
    if (process.hThread != NULL) CloseHandle(process.hThread);
    if (process.hProcess != NULL) CloseHandle(process.hProcess);
    heap_release(environment);
    heap_release(command_line);
    if (attributes != NULL) {
        if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
        HeapFree(GetProcessHeap(), 0, attributes);
    }
    if (launch_token != NULL) CloseHandle(launch_token);
    if (privilege_token != NULL) CloseHandle(privilege_token);
    heap_release(bytes);
    if (config.control_read != NULL) CloseHandle(config.control_read);
    if (config.control_write != NULL) CloseHandle(config.control_write);
    if (config.standard_handles[0] != NULL) CloseHandle(config.standard_handles[0]);
    if (config.standard_handles[1] != NULL) CloseHandle(config.standard_handles[1]);
    if (config.standard_handles[2] != NULL) CloseHandle(config.standard_handles[2]);
    if (config.query_job != NULL) CloseHandle(config.query_job);
    if (config.launcher_gate != NULL) CloseHandle(config.launcher_gate);
    if (config.supervisor_process != NULL) CloseHandle(config.supervisor_process);
    free_config(&config);
    return result;
}

__declspec(safebuffers) void WINAPI launcher_entry(void) {
    EntryArguments arguments;
    int result;
    __security_init_cookie();
    if (!parse_entry_arguments(&arguments)) ExitProcess(125u);
    result = launcher_run(&arguments);
    free_entry_arguments(&arguments);
    ExitProcess((UINT)result);
}
