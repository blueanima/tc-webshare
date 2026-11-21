/*
 * manage.c - list/mkdir/delete CGI for tc-webshare on AirPort Time Capsule.
 *
 * One static binary serves three endpoints through the single "-C .cgi"
 * handler mapping.  The action is selected from SCRIPT_NAME:
 *   /list.cgi   -> JSON array of the top-level entries of TC_SHARE_DIR
 *   /mkdir.cgi  -> create a directory in TC_SHARE_DIR (name from query or
 *                  application/x-www-form-urlencoded POST body)
 *   /delete.cgi -> remove ONE top-level file or EMPTY directory in
 *                  TC_SHARE_DIR (name from the same sources as mkdir)
 *   /move.cgi   -> move ONE top-level file or directory into an existing
 *                  top-level directory (name + to from form/query)
 *   /chpasswd.cgi -> replace the admin (or current Basic-auth user) entry in
 *                  the managed <ROOT>/etc/htpasswd with a fresh crypt(3)
 *                  "$1$" hash (POST form field new_password; optional
 *                  old_password is verified against the existing hash)
 *
 * v1.0.8 password handling: the hash is computed in THIS process with
 * crypt() from libcrypt (statically linked, like bozohttpd itself), so the
 * plaintext never reaches argv, a shell, a pipe or a child process.  The
 * password is wiped from our stack buffers before the CGI returns.  The
 * target file path is fixed relative to an install-time-baked TC_ETC_DIR
 * (or, for older dispatchers, derived from TC_STATE_DIR); no client input
 * can influence it.  Writes are atomic (same-directory temp + rename) and
 * keep mode 0600 and all other htpasswd users.
 *
 * Security rules (same strength as upload.c):
 *   - names may use ASCII [A-Za-z0-9._-] plus well-formed UTF-8 multibyte
 *     sequences (Chinese folder names work).  ".", "..", leading dots,
 *     path separators (/ and \), NUL/C0/C1/DEL controls, malformed UTF-8
 *     (overlong encodings, surrogates, values above U+10FFFF) and names
 *     longer than MAX_NAME bytes are all rejected.
 *   - move is strictly top level -> one existing top-level directory: no
 *     recursion, no cross-level paths, no symlink targets and no overwrite
 *     of an existing destination entry.
 *   - deletion stays in the SHARE_DIR top level: lstat() never follows
 *     symlinks, only regular files (unlink) and directories (rmdir, empty
 *     only) are accepted.  No recursion, so user data cannot be wiped.
 *   - the program files .htpasswd and .tc-webshare-index.html (and every
 *     other dotfile) can never be named, hence never deleted.
 *   - listing is non-recursive and skips all dotfiles.
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

/* Expose C99 strtoll (the NetBSD 7.2 headers hide it under gnu89).  Without
 * this the cross compiler warns about an implicit declaration and a 32-bit
 * caller silently truncates CONTENT_LENGTH above 2 GiB.  Same fix as upload.c
 * in v1.0.5. */
#ifndef _ISOC99_SOURCE
#define _ISOC99_SOURCE
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
/* NetBSD declares crypt() under _XOPEN_SOURCE (or _NETBSD_SOURCE).  Defining
 * _POSIX_C_SOURCE alone hides it and -Wall reports an implicit declaration. */
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
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
#define MAX_PASS 200           /* password bytes, not characters */
#define MAX_USER 64            /* htpasswd username bytes */
#define MAX_HASH 256           /* enough for $1$ / $2a$ / $6$ hashes */
#define MAX_HTPASSWD 16384     /* cap on a htpasswd file we will rewrite */

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

/* Is BYTE a UTF-8 continuation byte (0x80..0xBF)? */
static int is_utf8_cont(unsigned char byte) {
    return (byte & 0xc0) == 0x80;
}

/*
 * Strict UTF-8 validation of exactly N bytes.  We do not merely allow bytes
 * >= 0x80: every sequence is checked against the RFC 3629 rules so that a
 * malformed byte string cannot smuggle an ASCII separator or a traversal
 * component past the basename checks below.
 *
 * Rejected: stray continuations, 0xC0/0xC1 and 0xF5..0xFF lead bytes,
 * overlong 2/3/4-byte forms, UTF-16 surrogates (U+D800..U+DFFF) and code
 * points above U+10FFFF.  C0 controls, DEL and C1 controls (U+0080..U+009F)
 * are rejected as well; ordinary ASCII is left for the caller to filter.
 */
static int valid_utf8_bytes(const char *text, size_t n) {
    size_t i = 0;

    while (i < n) {
        unsigned char c = (unsigned char)text[i];

        if (c < 0x80) {
            if (c < 0x20 || c == 0x7f) return 0;   /* NUL/C0 controls, DEL. */
            i++;
            continue;
        }
        if (c >= 0xc2 && c <= 0xdf) {              /* 2 bytes: U+0080..U+07FF. */
            unsigned char c1 = 0;
            if (i + 1 >= n) return 0;
            c1 = (unsigned char)text[i + 1];
            if (!is_utf8_cont(c1)) return 0;
            if (c == 0xc2 && c1 <= 0x9f) return 0; /* C1 controls. */
            i += 2;
            continue;
        }
        if (c >= 0xe0 && c <= 0xef) {              /* 3 bytes: U+0800..U+FFFF. */
            unsigned char c1 = 0;
            unsigned char c2 = 0;
            if (i + 2 >= n) return 0;
            c1 = (unsigned char)text[i + 1];
            c2 = (unsigned char)text[i + 2];
            if (!is_utf8_cont(c1) || !is_utf8_cont(c2)) return 0;
            if (c == 0xe0 && c1 < 0xa0) return 0;  /* Overlong encoding. */
            if (c == 0xed && c1 > 0x9f) return 0;  /* UTF-16 surrogate. */
            i += 3;
            continue;
        }
        if (c >= 0xf0 && c <= 0xf4) {              /* 4 bytes: U+10000..U+10FFFF. */
            unsigned char c1 = 0;
            unsigned char c2 = 0;
            unsigned char c3 = 0;
            if (i + 3 >= n) return 0;
            c1 = (unsigned char)text[i + 1];
            c2 = (unsigned char)text[i + 2];
            c3 = (unsigned char)text[i + 3];
            if (!is_utf8_cont(c1) || !is_utf8_cont(c2) || !is_utf8_cont(c3)) {
                return 0;
            }
            if (c == 0xf0 && c1 < 0x90) return 0;  /* Overlong encoding. */
            if (c == 0xf4 && c1 > 0x8f) return 0;  /* Above U+10FFFF. */
            i += 4;
            continue;
        }
        return 0;   /* 0x80..0xBF stray continuation, 0xC0/0xC1, 0xF5..0xFF. */
    }
    return 1;
}

/*
 * Basename policy shared by mkdir and delete.  ASCII separators are checked
 * explicitly (they can only occur as whole ASCII bytes in well-formed
 * UTF-8), the full "." and ".." strings and all leading dots are refused,
 * and the remaining bytes must be well-formed UTF-8 without controls.
 */
static int valid_folder_name(const char *name) {
    size_t n = 0;

    if (name == NULL) return 0;
    n = strlen(name);
    if (n == 0 || n > MAX_NAME) return 0;
    if (name[0] == '.') return 0;                  /* Also covers "." / "..". */
    if (strchr(name, '/') != NULL || strchr(name, '\\') != NULL) return 0;
    return valid_utf8_bytes(name, n);
}

/* Program files must never be deletable; valid_folder_name already rejects
 * them because they are dotfiles.  Keep this explicit as a second barrier. */
static int is_program_file(const char *name) {
    return strcmp(name, ".htpasswd") == 0 ||
           strcmp(name, ".tc-webshare-index.html") == 0;
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

/*
 * Delete exactly one top-level entry of SHARE_DIR.  The name goes through
 * the same validator as mkdir, so it is always a basename (no separators,
 * no "..", no leading dot, no malformed UTF-8).  lstat() is used so that a
 * symlink is recognised and refused instead of being followed; unlink() of
 * a symlink would only remove the link anyway, and rmdir() of one fails.
 * Directories are removed with rmdir() only: never recurse into user data.
 */
static int action_delete(void) {
    char input[MAX_BODY + 1];
    char name[MAX_NAME + 1];
    char path[PATH_MAX];
    struct stat sb;
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
    if (!valid_folder_name(name) || is_program_file(name)) {
        return cgi_fail(400, "name rejected by security policy");
    }

    (void)snprintf(path, sizeof(path), "%s/%s", g_share_dir, name);
    if (lstat(path, &sb) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return cgi_fail(404, "not found");
        return cgi_fail(500, "cannot stat entry");
    }
    if (S_ISLNK(sb.st_mode)) {
        return cgi_fail(403, "symlinks cannot be deleted");
    }

    if (S_ISDIR(sb.st_mode)) {
        if (rmdir(path) != 0) {
            if (errno == ENOTEMPTY || errno == EEXIST) {
                return cgi_fail(409, "directory not empty");
            }
            if (errno == ENOENT) return cgi_fail(404, "not found");
            return cgi_fail(500, "cannot remove directory");
        }
    } else if (S_ISREG(sb.st_mode)) {
        if (unlink(path) != 0) {
            if (errno == ENOENT) return cgi_fail(404, "not found");
            return cgi_fail(500, "cannot remove file");
        }
    } else {
        return cgi_fail(403, "unsupported file type");
    }

    json_header();
    printf("{\"ok\":true,\"name\":");
    json_string(name);
    printf("}\n");
    return 0;
}

/*
 * Move exactly one top-level entry into an existing top-level directory.
 * Both names go through the same validator as mkdir/delete, so neither can
 * contain separators, "..", a leading dot, program-file names, controls or
 * malformed UTF-8.  The source and the destination directory are checked
 * with lstat(): symlinks are refused, so data can never be moved outside
 * SHARE_DIR.  The destination entry is checked before rename() so an
 * existing file or folder is never overwritten.  Only one level is crossed;
 * this is not a recursive move.
 */
static int action_move(void) {
    char input[MAX_BODY + 1];
    char name[MAX_NAME + 1];
    char to[MAX_NAME + 1];
    char src_path[PATH_MAX];
    char dir_path[PATH_MAX];
    char dst_path[PATH_MAX];
    struct stat sb;
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

    if (form_value(input, "name", name, sizeof(name)) != 0 ||
        form_value(input, "to", to, sizeof(to)) != 0) {
        return cgi_fail(400, "missing or malformed 'name'/'to' parameter");
    }
    if (!valid_folder_name(name) || is_program_file(name) ||
        !valid_folder_name(to) || is_program_file(to)) {
        return cgi_fail(400, "name rejected by security policy");
    }
    if (strcmp(name, to) == 0) {
        return cgi_fail(409, "source and destination folder are the same");
    }

    (void)snprintf(src_path, sizeof(src_path), "%s/%s", g_share_dir, name);
    (void)snprintf(dir_path, sizeof(dir_path), "%s/%s", g_share_dir, to);
    (void)snprintf(dst_path, sizeof(dst_path), "%s/%s/%s", g_share_dir, to, name);

    if (lstat(src_path, &sb) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return cgi_fail(404, "source not found");
        return cgi_fail(500, "cannot stat source");
    }
    if (S_ISLNK(sb.st_mode)) {
        return cgi_fail(403, "symlinks cannot be moved");
    }
    if (!S_ISREG(sb.st_mode) && !S_ISDIR(sb.st_mode)) {
        return cgi_fail(403, "unsupported file type");
    }

    if (lstat(dir_path, &sb) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return cgi_fail(404, "destination folder not found");
        return cgi_fail(500, "cannot stat destination folder");
    }
    if (S_ISLNK(sb.st_mode)) {
        return cgi_fail(403, "symlink folders cannot be used as destination");
    }
    if (!S_ISDIR(sb.st_mode)) {
        return cgi_fail(403, "destination is not a directory");
    }

    /* Never overwrite user data.  lstat() also sees a dangling symlink. */
    if (lstat(dst_path, &sb) == 0) {
        return cgi_fail(409, "destination already exists");
    }
    if (errno != ENOENT && errno != ENOTDIR) {
        return cgi_fail(500, "cannot stat destination");
    }

    if (rename(src_path, dst_path) != 0) {
        if (errno == EEXIST || errno == ENOTEMPTY) {
            return cgi_fail(409, "destination already exists");
        }
        if (errno == ENOENT || errno == ENOTDIR) {
            return cgi_fail(404, "source or destination not found");
        }
        return cgi_fail(500, "cannot move entry");
    }

    json_header();
    printf("{\"ok\":true,\"name\":");
    json_string(name);
    printf(",\"to\":");
    json_string(to);
    printf("}\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* v1.0.8: Web password change                                        */
/* ------------------------------------------------------------------ */

/* True when KEY appears as a complete name in a urlencoded body.  form_value()
 * uses -1 for both "absent" and "malformed"; this lets callers tell an
 * intentionally omitted optional field from a broken one. */
static int form_has_key(const char *buf, const char *key) {
    size_t key_len = strlen(key);
    const char *p = buf;
    size_t remaining = strlen(buf);

    while (remaining > 0) {
        const char *amp = memchr(p, '&', remaining);
        size_t part_len = (amp != NULL) ? (size_t)(amp - p) : remaining;
        const char *eq = memchr(p, '=', part_len);
        size_t name_len = (eq != NULL) ? (size_t)(eq - p) : part_len;

        if (name_len == key_len && memcmp(p, key, key_len) == 0) return 1;
        if (amp == NULL) break;
        p = amp + 1;
        remaining -= part_len + 1;
    }
    return 0;
}

/* Passwords may be UTF-8 (the on-device helper accepts any text line), but
 * NUL, C0/C1 controls and DEL are refused.  valid_utf8_bytes() already
 * enforces exactly those rules plus RFC 3629 well-formedness. */
static int valid_password(const char *password) {
    size_t n = 0;

    if (password == NULL || password[0] == '\0') return 0;
    n = strlen(password);
    if (n > MAX_PASS) return 0;
    return valid_utf8_bytes(password, n);
}

/* htpasswd usernames are a deliberately small, colon-free subset. */
static int valid_user_bytes(const char *user, size_t n) {
    size_t i = 0;

    if (user == NULL || n == 0 || n > MAX_USER) return 0;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)user[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static int valid_user_name(const char *user) {
    return (user != NULL) ? valid_user_bytes(user, strlen(user)) : 0;
}

/* Only a plain absolute path with no "." / ".." / empty components is
 * accepted.  All values come from install-time-baked env vars, never from
 * the browser, but refusing odd paths keeps the write target predictable. */
static int safe_path(const char *path) {
    const char *p = NULL;

    if (path == NULL || path[0] != '/' || path[0] == '\0') return 0;
    if (strlen(path) + 1 > PATH_MAX) return 0;
    p = path + 1;
    while (*p != '\0') {
        const char *slash = strchr(p, '/');
        size_t len = (slash != NULL) ? (size_t)(slash - p) : strlen(p);
        if (len == 0) return 0;                     /* "//" */
        if (len == 1 && p[0] == '.') return 0;
        if (len == 2 && p[0] == '.' && p[1] == '.') return 0;
        if (slash == NULL) break;
        p = slash + 1;
    }
    return 1;
}

/*
 * Resolve the managed ETC_DIR.  New dispatchers export TC_ETC_DIR directly
 * (baked by install.sh); dispatchers from v1.0.7 and earlier only export
 * TC_STATE_DIR, so derive <ROOT>/etc = dirname(TC_STATE_DIR)/etc as a
 * compatibility fallback.  Both inputs are install-controlled constants.
 */
static int resolve_etc_dir(char *dst, size_t dst_size) {
    const char *etc = getenv("TC_ETC_DIR");
    const char *state = NULL;
    char state_copy[PATH_MAX];
    char *slash = NULL;
    size_t n = 0;

    if (etc != NULL && etc[0] != '\0') {
        n = (size_t)snprintf(dst, dst_size, "%s", etc);
    } else {
        state = getenv("TC_STATE_DIR");
        if (state == NULL || state[0] == '\0') return 0;
        (void)snprintf(state_copy, sizeof(state_copy), "%s", state);
        slash = strrchr(state_copy, '/');
        if (slash == NULL || slash == state_copy || slash[1] == '\0') return 0;
        *slash = '\0';
        if (!safe_path(state_copy)) return 0;
        n = (size_t)snprintf(dst, dst_size, "%s/etc", state_copy);
    }
    if (n == 0 || n >= dst_size) return 0;
    return safe_path(dst);
}

/* Length of the username before the first ':' in one htpasswd line. */
static size_t htpasswd_user_len(const char *line, size_t line_len) {
    size_t i = 0;

    for (i = 0; i < line_len; i++) {
        if (line[i] == ':') return i;
    }
    return 0;
}

/* Copy the hash field of USER into HASH.  Returns 1 when found. */
static int htpasswd_find_user(const char *buf, size_t buf_len,
                              const char *user, char *hash, size_t hash_size) {
    const char *p = buf;
    size_t remaining = buf_len;

    hash[0] = '\0';
    while (remaining > 0) {
        const char *nl = memchr(p, '\n', remaining);
        size_t line_len = (nl != NULL) ? (size_t)(nl - p) : remaining;
        size_t user_len = htpasswd_user_len(p, line_len);
        size_t hash_len = 0;

        if (user_len > 0 && user_len == strlen(user) &&
            memcmp(p, user, user_len) == 0) {
            hash_len = line_len - user_len - 1;
            if (hash_len > 0 && p[line_len - 1] == '\r') hash_len--;
            if (hash_len >= hash_size) return 0;
            memcpy(hash, p + user_len + 1, hash_len);
            hash[hash_len] = '\0';
            return 1;
        }
        if (nl == NULL) break;
        p = nl + 1;
        remaining -= line_len + 1;
    }
    return 0;
}

/* Count user lines; when exactly one exists, copy its name into FIRST. */
static int htpasswd_user_count(const char *buf, size_t buf_len,
                               char *first, size_t first_size) {
    const char *p = buf;
    size_t remaining = buf_len;
    int count = 0;

    first[0] = '\0';
    while (remaining > 0) {
        const char *nl = memchr(p, '\n', remaining);
        size_t line_len = (nl != NULL) ? (size_t)(nl - p) : remaining;
        size_t user_len = htpasswd_user_len(p, line_len);

        if (user_len > 0 && valid_user_bytes(p, user_len)) {
            count++;
            if (count == 1) {
                size_t n = (user_len >= first_size) ? first_size - 1 : user_len;
                memcpy(first, p, n);
                first[n] = '\0';
            }
            if (count > 1) break;
        }
        if (nl == NULL) break;
        p = nl + 1;
        remaining -= line_len + 1;
    }
    return count;
}

/*
 * Pick the entry to rotate.  bozohttpd may expose the authenticated name as
 * REMOTE_USER: if it names an existing user we rotate exactly that account
 * (important for installs made with TC_WEB_USER != admin).  Otherwise prefer
 * "admin" when present, then the sole existing user, then "admin" as a new
 * entry.  Remaining users are always preserved.
 */
static void choose_target_user(const char *buf, size_t buf_len,
                               char *user, size_t user_size) {
    const char *remote = getenv("REMOTE_USER");
    char hash[MAX_HASH];
    char first[MAX_USER + 1];
    int count = 0;

    if (remote != NULL && valid_user_name(remote) &&
        htpasswd_find_user(buf, buf_len, remote, hash, sizeof(hash))) {
        (void)snprintf(user, user_size, "%s", remote);
        return;
    }
    if (htpasswd_find_user(buf, buf_len, "admin", hash, sizeof(hash))) {
        (void)snprintf(user, user_size, "admin");
        return;
    }
    count = htpasswd_user_count(buf, buf_len, first, sizeof(first));
    if (count == 1 && first[0] != '\0') {
        (void)snprintf(user, user_size, "%s", first);
        return;
    }
    (void)snprintf(user, user_size, "admin");
}

/* 8-character MD5-crypt salt from [./0-9A-Za-z], never a secret. */
static void make_salt(char salt[9]) {
    static const char alphabet[] =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    static unsigned int counter = 0;
    unsigned char bytes[8];
    ssize_t got = 0;
    int fd = -1;
    unsigned int mix = 0;
    size_t i = 0;

    fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        while (got < (ssize_t)sizeof(bytes)) {
            ssize_t n = read(fd, bytes + got, sizeof(bytes) - (size_t)got);
            if (n > 0) {
                got += n;
            } else if (n < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
        (void)close(fd);
    }
    if (got != (ssize_t)sizeof(bytes)) {
        /* Fallback: uniqueness only.  A salt is not a secret. */
        counter++;
        mix = (unsigned int)getpid() ^ (unsigned int)time(NULL) ^
              (unsigned int)(uintptr_t)&counter ^ (counter * 2654435761u);
        for (i = 0; i < sizeof(bytes); i++) {
            mix = mix * 1103515245u + 12345u;
            bytes[i] = (unsigned char)(mix >> 16);
        }
    }
    for (i = 0; i < sizeof(bytes); i++) {
        salt[i] = alphabet[bytes[i] & 0x3f];
    }
    salt[8] = '\0';
}

/* Copy all htpasswd lines except USER, then append USER:HASH. */
static int build_htpasswd(const char *src, size_t src_len,
                          const char *user, const char *hash,
                          char *out, size_t out_size) {
    const char *p = src;
    size_t remaining = src_len;
    size_t used = 0;
    size_t need = 0;
    size_t user_len = strlen(user);

    while (remaining > 0) {
        const char *nl = memchr(p, '\n', remaining);
        size_t line_len = (nl != NULL) ? (size_t)(nl - p) : remaining;
        size_t name_len = htpasswd_user_len(p, line_len);
        int skip = (name_len == user_len && memcmp(p, user, user_len) == 0);
        size_t extra = 0;

        if (!skip) {
            extra = (nl != NULL) ? 1 : 0;            /* preserve newline */
            need = line_len + extra;
            if (need > out_size - used - 1) return 0;
            memcpy(out + used, p, line_len);
            used += line_len;
            if (extra != 0) out[used++] = '\n';
        }
        if (nl == NULL) break;
        p = nl + 1;
        remaining -= line_len + 1;
    }

    need = user_len + 1 + strlen(hash) + 1;         /* user:hash\n */
    if (need > out_size - used - 1) return 0;
    memcpy(out + used, user, user_len);
    used += user_len;
    out[used++] = ':';
    (void)memcpy(out + used, hash, strlen(hash));
    used += strlen(hash);
    out[used++] = '\n';
    out[used] = '\0';
    return 1;
}

/* Same-directory temp file + rename(): readers see either the old or the new
 * complete file, never a half-written one.  The docroot .htpasswd symlink
 * points at this path, so no restart or link update is needed. */
static int write_htpasswd_atomic(const char *etc_dir,
                                 const char *content, size_t content_len) {
    char final_path[PATH_MAX];
    char tmp_path[PATH_MAX];
    struct stat sb;
    int fd = -1;
    int rc = -1;
    int attempt = 0;
    size_t written = 0;

    (void)snprintf(final_path, sizeof(final_path), "%s/htpasswd", etc_dir);
    if (!safe_path(final_path)) return -1;
    if (lstat(final_path, &sb) == 0) {
        if (!S_ISREG(sb.st_mode)) return -1;        /* refuse symlink/special */
    } else if (errno != ENOENT) {
        return -1;
    }

    for (attempt = 0; attempt < 100; attempt++) {
        (void)snprintf(tmp_path, sizeof(tmp_path), "%s/.htpasswd.tmp.%ld.%d",
                       etc_dir, (long)getpid(), attempt);
#ifdef O_NOFOLLOW
        fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
#else
        /* O_EXCL alone already refuses a pre-existing symlink; O_NOFOLLOW
         * on NetBSD is defence in depth against a race. */
        fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
#endif
        if (fd >= 0) break;
        if (errno != EEXIST) return -1;
    }
    if (fd < 0) return -1;

    while (written < content_len) {
        ssize_t n = write(fd, content + written, content_len - written);
        if (n > 0) {
            written += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            goto cleanup;
        }
    }
    if (fchmod(fd, 0600) != 0) goto cleanup;
    /* The device's mfs/Flash is synchronous; a failed fsync is not a reason
     * to discard an otherwise complete rename. */
    (void)fsync(fd);
    if (close(fd) != 0) {
        fd = -1;
        goto cleanup;
    }
    fd = -1;
    if (rename(tmp_path, final_path) != 0) goto cleanup;
    rc = 0;

cleanup:
    if (fd >= 0) (void)close(fd);
    if (rc != 0) (void)unlink(tmp_path);
    return rc;
}

static int chpasswd_commit(const char *password,
                           const char *old_password, int has_old) {
    char etc_dir[PATH_MAX];
    char content[MAX_HTPASSWD + 1];
    char rebuilt[MAX_HTPASSWD + MAX_HASH + MAX_USER + 16];
    char user[MAX_USER + 1];
    char existing_hash[MAX_HASH];
    char salt[9];
    char setting[16];
    char *encoded = NULL;
    size_t content_len = 0;

    if (!resolve_etc_dir(etc_dir, sizeof(etc_dir))) {
        return cgi_fail(500, "managed etc directory unavailable");
    }

    content[0] = '\0';
    {
        char htpasswd_path[PATH_MAX];
        struct stat sb;
        FILE *fp = NULL;

        (void)snprintf(htpasswd_path, sizeof(htpasswd_path), "%s/htpasswd",
                       etc_dir);
        if (!safe_path(htpasswd_path)) {
            return cgi_fail(500, "managed htpasswd path rejected");
        }
        if (lstat(htpasswd_path, &sb) == 0) {
            if (!S_ISREG(sb.st_mode)) {
                return cgi_fail(500, "managed htpasswd is not a regular file");
            }
            fp = fopen(htpasswd_path, "rb");
        } else if (errno == ENOENT) {
            fp = NULL;                              /* create on first change */
        } else {
            return cgi_fail(500, "cannot stat managed htpasswd");
        }
        if (fp != NULL) {
            content_len = fread(content, 1, MAX_HTPASSWD, fp);
            if (ferror(fp) != 0) {
                (void)fclose(fp);
                return cgi_fail(500, "cannot read managed htpasswd");
            }
            (void)fclose(fp);
        }
        content[content_len] = '\0';
    }

    choose_target_user(content, content_len, user, sizeof(user));

    if (has_old) {
        if (!valid_password(old_password)) {
            return cgi_fail(400, "invalid 'old_password' parameter");
        }
        if (!htpasswd_find_user(content, content_len, user,
                                existing_hash, sizeof(existing_hash)) ||
            existing_hash[0] == '\0') {
            return cgi_fail(403, "old password check unavailable");
        }
        encoded = crypt(old_password, existing_hash);
        if (encoded == NULL || strcmp(encoded, existing_hash) != 0) {
            return cgi_fail(403, "old password does not match");
        }
    }

    make_salt(salt);
    (void)snprintf(setting, sizeof(setting), "$1$%s", salt);
    encoded = crypt(password, setting);
    if (encoded == NULL || strncmp(encoded, "$1$", 3) != 0 ||
        strlen(encoded) >= MAX_HASH) {
        return cgi_fail(500, "password hash generation failed");
    }
    if (!build_htpasswd(content, content_len, user, encoded,
                        rebuilt, sizeof(rebuilt))) {
        return cgi_fail(500, "htpasswd too large to rewrite");
    }
    if (write_htpasswd_atomic(etc_dir, rebuilt, strlen(rebuilt)) != 0) {
        return cgi_fail(500, "cannot write managed htpasswd");
    }

    json_header();
    printf("{\"ok\":true}\n");                     /* never echo hash/password */
    return 0;
}

static int action_chpasswd(void) {
    char input[MAX_BODY + 1];
    char password[MAX_PASS + 2];
    char old_password[MAX_PASS + 2];
    const char *type = NULL;
    int has_old = 0;
    int rc = 0;

    input[0] = '\0';
    password[0] = '\0';
    old_password[0] = '\0';

    /* A password in a query string would land in proxy/browser history. */
    type = getenv("CONTENT_TYPE");
    if (type == NULL ||
        strncasecmp(type, "application/x-www-form-urlencoded", 33) != 0) {
        return cgi_fail(400, "chpasswd requires a form POST");
    }
    if (read_body(input, sizeof(input)) != 0) {
        /* read_body may have copied part of the password before failing. */
        memset(input, 0, sizeof(input));
        return cgi_fail(400, "invalid request body");
    }
    if (form_value(input, "new_password", password, sizeof(password)) != 0 ||
        !valid_password(password)) {
        memset(input, 0, sizeof(input));
        memset(password, 0, sizeof(password));
        return cgi_fail(400,
            "missing, empty, overlong or malformed 'new_password' parameter");
    }

    has_old = form_has_key(input, "old_password");
    old_password[0] = '\0';
    if (has_old &&
        form_value(input, "old_password", old_password,
                   sizeof(old_password)) != 0) {
        has_old = 0;                                /* malformed: ignore */
    }

    rc = chpasswd_commit(password, old_password, has_old);

    /* Keep plaintext off our stack for as long as the process lives. */
    memset(input, 0, sizeof(input));
    memset(password, 0, sizeof(password));
    memset(old_password, 0, sizeof(old_password));
    return rc;
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
    if (strstr(script, "delete.cgi") != NULL) {
        return action_delete();
    }
    if (strstr(script, "move.cgi") != NULL) {
        return action_move();
    }
    if (strstr(script, "chpasswd.cgi") != NULL) {
        return action_chpasswd();
    }
    return cgi_fail(404, "unknown management action");
}
