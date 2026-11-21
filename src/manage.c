/*
 * manage.c - list/mkdir CGI for tc-webshare on AirPort Time Capsule.
 *
 * One static binary serves two endpoints through the single "-C .cgi"
 * handler mapping.  The action is selected from SCRIPT_NAME:
 *   /list.cgi   -> JSON array of the top-level entries of TC_SHARE_DIR
 *   /mkdir.cgi  -> create a directory in TC_SHARE_DIR (name from query or
 *                  application/x-www-form-urlencoded POST body)
 *
 * Security rules (same strength as upload.c):
 *   - only basenames matching [A-Za-z0-9._-] are accepted for mkdir;
 *     ".", "..", leading dots, absolute paths and separators are rejected.
 *   - listing is non-recursive and skips all dotfiles (including .htpasswd
 *     and the generated hidden homepage).
 *   - JSON strings are escaped; no shell is involved.
 *
 * Build (inside the cross-build container, with --sysroot):
 *   armv4--netbsdelf-eabi-gcc --sysroot=<sysroot> -O2 -g0 -static \
 *     -fno-pic -fno-PIE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE \
 *     -o manage.cgi manage.c
 *
 * Copyright (C) 2026 tc-webshare contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define MAX_NAME 200
#define MAX_BODY 4096
#define MAX_ENTRIES 5000
#define DEFAULT_SHARE_DIR "/Volumes/dk2/share/web"

typedef struct {
    char name[MAX_NAME + 1];
    off_t size;
    time_t mtime;
    int is_dir;
} entry_t;

static const char *g_share_dir = DEFAULT_SHARE_DIR;

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static void json_string(const char *text);

static void json_header(void) {
    printf("Content-Type: application/json; charset=utf-8\r\n");
    printf("Cache-Control: no-store\r\n\r\n");
}

static int cgi_fail(int code, const char *reason) {
    printf("Status: %d %s\r\n", code,
           code == 400 ? "Bad Request" :
           code == 403 ? "Forbidden" :
           code == 404 ? "Not Found" :
           code == 409 ? "Conflict" : "Internal Server Error");
    json_header();
    printf("{\"ok\":false,\"error\":");
    json_string(reason);
    printf("}\n");
    return 0;
}

static void json_string_impl(const char *text) {
    const unsigned char *p = NULL;

    if (text == NULL) {
        printf("\"\"");
        return;
    }
    putchar('"');
    for (p = (const unsigned char *)text; *p != '\0'; p++) {
        unsigned char c = *p;
        switch (c) {
            case '"':  printf("\\\""); break;
            case '\\': printf("\\\\"); break;
            case '\b': printf("\\b"); break;
            case '\f': printf("\\f"); break;
            case '\n': printf("\\n"); break;
            case '\r': printf("\\r"); break;
            case '\t': printf("\\t"); break;
            default:
                if (c < 0x20) {
                    printf("\\u%04x", (unsigned int)c);
                } else {
                    putchar((int)c);
                }
                break;
        }
    }
    putchar('"');
}

static void json_string(const char *text) {
    json_string_impl(text);
}

static int hex_value(unsigned char c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a') + 10;
    if (c >= 'A' && c <= 'F') return (int)(c - 'A') + 10;
    return -1;
}

/* Decode '+' and %XX into OUT; returns 0 on success, -1 on bad escape or
 * overflow.  NUL bytes are rejected. */
static int url_decode(const char *src, size_t src_len, char *out, size_t out_size) {
    size_t i = 0;
    size_t n = 0;

    for (i = 0; i < src_len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '+') {
            c = ' ';
        } else if (c == '%') {
            int hi = 0;
            int lo = 0;
            if (i + 2 >= src_len) return -1;
            hi = hex_value((unsigned char)src[i + 1]);
            lo = hex_value((unsigned char)src[i + 2]);
            if (hi < 0 || lo < 0) return -1;
            c = (unsigned char)((hi << 4) | lo);
            i += 2;
        }
        if (c == 0) return -1;
        if (n + 1 >= out_size) return -1;
        out[n++] = (char)c;
    }
    out[n] = '\0';
    return 0;
}

/* Extract the value of KEY from a urlencoded buffer. */
static int form_value(const char *buf, const char *key, char *out, size_t out_size) {
    size_t key_len = strlen(key);
    const char *p = buf;
    size_t remaining = strlen(buf);

    out[0] = '\0';
    while (remaining > 0) {
        const char *amp = memchr(p, '&', remaining);
        size_t part_len = (amp != NULL) ? (size_t)(amp - p) : remaining;
        const char *eq = memchr(p, '=', part_len);
        size_t name_len = (eq != NULL) ? (size_t)(eq - p) : part_len;
        const char *value = (eq != NULL) ? eq + 1 : p + part_len;
        size_t value_len = (eq != NULL) ? part_len - name_len - 1 : 0;

        if (name_len == key_len && memcmp(p, key, key_len) == 0) {
            return url_decode(value, value_len, out, out_size);
        }
        if (amp == NULL) break;
        p = amp + 1;
        remaining -= part_len + 1;
    }
    return -1;
}

static int valid_folder_name(const char *name) {
    size_t i = 0;
    size_t n = 0;

    if (name == NULL) return 0;
    n = strlen(name);
    if (n == 0 || n > MAX_NAME) return 0;
    if (name[0] == '.' || name[0] == '/' || name[0] == '\\') return 0;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return 0;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)name[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static void json_time(char *dst, size_t dst_size, time_t value) {
    struct tm tm_buf;
    if (gmtime_r(&value, &tm_buf) != NULL) {
        (void)strftime(dst, dst_size, "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
    } else {
        (void)snprintf(dst, dst_size, "unknown");
    }
}

static int entry_cmp(const void *a, const void *b) {
    const entry_t *ea = (const entry_t *)a;
    const entry_t *eb = (const entry_t *)b;
    return strcmp(ea->name, eb->name);
}

/* ------------------------------------------------------------------ */
/* actions                                                            */
/* ------------------------------------------------------------------ */

static int action_list(void) {
    DIR *dir = NULL;
    struct dirent *de = NULL;
    entry_t *entries = NULL;
    size_t count = 0;
    size_t i = 0;
    char path[PATH_MAX];

    dir = opendir(g_share_dir);
    if (dir == NULL) {
        return cgi_fail(500, "cannot open share directory");
    }

    entries = (entry_t *)calloc(MAX_ENTRIES, sizeof(entry_t));
    if (entries == NULL) {
        closedir(dir);
        return cgi_fail(500, "out of memory");
    }

    while ((de = readdir(dir)) != NULL && count < MAX_ENTRIES) {
        struct stat sb;
        const char *name = de->d_name;
        if (name[0] == '.' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
            continue;
        }
        if (strlen(name) > MAX_NAME) continue;
        (void)snprintf(path, sizeof(path), "%s/%s", g_share_dir, name);
        if (lstat(path, &sb) != 0) continue;
        if (!S_ISREG(sb.st_mode) && !S_ISDIR(sb.st_mode)) continue;
        (void)strncpy(entries[count].name, name, MAX_NAME);
        entries[count].name[MAX_NAME] = '\0';
        entries[count].size = (S_ISDIR(sb.st_mode)) ? (off_t)0 : sb.st_size;
        entries[count].mtime = sb.st_mtime;
        entries[count].is_dir = S_ISDIR(sb.st_mode) ? 1 : 0;
        count++;
    }
    closedir(dir);

    if (count > 1) {
        qsort(entries, count, sizeof(entry_t), entry_cmp);
    }

    json_header();
    printf("[");
    for (i = 0; i < count; i++) {
        char stamp[32];
        json_time(stamp, sizeof(stamp), entries[i].mtime);
        if (i != 0) printf(",");
        printf("{\"name\":");
        json_string(entries[i].name);
        printf(",\"size\":%lld,\"mtime\":\"%s\",\"dir\":%s}",
               (long long)entries[i].size, stamp,
               entries[i].is_dir ? "true" : "false");
    }
    printf("]\n");
    free(entries);
    return 0;
}

static int read_body(char *buf, size_t buf_size) {
    const char *len_text = getenv("CONTENT_LENGTH");
    long long want = 0;
    size_t got = 0;
    char *end_ptr = NULL;

    buf[0] = '\0';
    if (len_text == NULL || len_text[0] == '\0') return 0;
    errno = 0;
    want = strtoll(len_text, &end_ptr, 10);
    if (errno != 0 || end_ptr == len_text || *end_ptr != '\0' || want <= 0) {
        return -1;
    }
    if ((unsigned long long)want >= buf_size) return -1;
    while (got < (size_t)want) {
        ssize_t n = read(STDIN_FILENO, buf + got, (size_t)want - got);
        if (n > 0) {
            got += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    buf[got] = '\0';
    return 0;
}

static int action_mkdir(void) {
    char input[MAX_BODY + 1];
    char name[MAX_NAME + 1];
    char path[PATH_MAX];
    const char *query = NULL;
    const char *type = NULL;
    int rc = 0;

    type = getenv("CONTENT_TYPE");
    if (type != NULL && strncasecmp(type, "application/x-www-form-urlencoded", 33) == 0) {
        rc = read_body(input, sizeof(input));
        if (rc != 0) return cgi_fail(400, "invalid request body");
    } else {
        query = getenv("QUERY_STRING");
        (void)snprintf(input, sizeof(input), "%s", (query != NULL) ? query : "");
    }

    if (form_value(input, "name", name, sizeof(name)) != 0) {
        return cgi_fail(400, "missing or malformed 'name' parameter");
    }
    if (!valid_folder_name(name)) {
        return cgi_fail(400, "folder name rejected by security policy");
    }

    (void)snprintf(path, sizeof(path), "%s/%s", g_share_dir, name);
    if (mkdir(path, 0755) != 0) {
        if (errno == EEXIST) return cgi_fail(409, "folder already exists");
        return cgi_fail(500, "cannot create folder");
    }

    json_header();
    printf("{\"ok\":true,\"name\":");
    json_string(name);
    printf("}\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    const char *env_value = NULL;
    const char *script = NULL;

    (void)umask(0022);
    env_value = getenv("TC_SHARE_DIR");
    if (env_value != NULL && env_value[0] != '\0') {
        g_share_dir = env_value;
    }

    script = getenv("SCRIPT_NAME");
    if (script == NULL) {
        return cgi_fail(400, "SCRIPT_NAME is missing");
    }
    if (strstr(script, "list.cgi") != NULL) {
        return action_list();
    }
    if (strstr(script, "mkdir.cgi") != NULL) {
        return action_mkdir();
    }
    return cgi_fail(404, "unknown management action");
}
