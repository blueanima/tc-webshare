/*
 * upload.cgi - streaming multipart/form-data upload CGI for thttpd on
 * AirPort Time Capsule (NetBSD 6.0 / evbarm / earmv4, static ELF only).
 *
 * Build (inside the cross-build container):
 *   armv4--netbsdelf-eabi-gcc -static -D_FILE_OFFSET_BITS=64 \
 *       -D_LARGEFILE_SOURCE -O2 -o upload.cgi upload.c
 *
 * Design rules (do not violate):
 *   - The request body is read from stdin as a stream; at most 64 KiB +
 *     a small boundary-carry buffer is resident at any time.
 *   - File names must already be basenames; no traversal, no absolute paths,
 *     no path separators, no "..", no NUL/control bytes.  Since v1.0.6 the
 *     remaining bytes must be printable ASCII or well-formed UTF-8, using
 *     the SAME strict RFC 3629 validator as manage.c (Chinese/emoji names
 *     are allowed, malformed sequences are not).
 *   - Target files are created with O_EXCL|O_NOFOLLOW; collisions get a
 *     numeric suffix. Existing files are never overwritten.
 *   - Exactly one upload at a time: an O_EXCL lockfile in the state dir.
 *   - Only libc/POSIX is used. off_t must be 64-bit (LFS) at build time.
 *
 * Copyright (C) 2026 tc-webshare contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/* Expose C99 declarations (notably strtoll).  Without this the NetBSD 7.2
 * headers hide strtoll under the plain gnu89 default, the cross compiler
 * warns about an implicit declaration, and a 32-bit caller silently truncates
 * CONTENT_LENGTH above 2 GiB back to int. */
#ifndef _ISOC99_SOURCE
#define _ISOC99_SOURCE
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define IO_CHUNK 65536                       /* 64 KiB on-disk write chunks. */
#define IO_BUFSZ (IO_CHUNK + 1024)           /* Slack for boundary carry.   */
#define MAX_FILENAME 200
#define MAX_BOUNDARY 200
#define MAX_LINE 4096
#define MAX_ATTEMPTS 1000
#define DEFAULT_SHARE_DIR "/Volumes/dk2/share/web"
#define DEFAULT_STATE_DIR "/Volumes/dk2/.tc_webshare/state"
#define LOCK_NAME "upload.lock"
#define LOG_NAME "upload.log"

typedef struct {
    unsigned char data[IO_BUFSZ];
    size_t pos;
    size_t len;
    int eof;
} io_t;

enum {
    BODY_END = 0,
    BODY_NEXT = 1,
    BODY_ERR = -1,
    BODY_TRUNC = -2
};

static char g_lock_path[PATH_MAX] = {0};
static int g_lock_fd = -1;
static off_t g_written = 0;

/* ------------------------------------------------------------------ */
/* Locking / logging                                                   */
/* ------------------------------------------------------------------ */

static void cleanup_lock(void) {
    if (g_lock_fd >= 0) {
        (void)close(g_lock_fd);
        g_lock_fd = -1;
    }
    if (g_lock_path[0] != '\0') {
        (void)unlink(g_lock_path);
        g_lock_path[0] = '\0';
    }
}

static void on_fatal_signal(int sig) {
    (void)sig;
    cleanup_lock();
    _exit(1);
}

static void log_event(const char *status, off_t bytes, const char *detail) {
    const char *state = getenv("TC_STATE_DIR");
    char path[PATH_MAX];
    char stamp[32];
    const char *remote = getenv("REMOTE_ADDR");
    time_t now = time(NULL);
    struct tm tm_buf;
    FILE *fp = NULL;

    if (state == NULL || state[0] == '\0') {
        state = DEFAULT_STATE_DIR;
    }
    (void)snprintf(path, sizeof(path), "%s/%s", state, LOG_NAME);
    fp = fopen(path, "a");
    if (fp == NULL) {
        return;                 /* Logging must never break an upload. */
    }
    if (gmtime_r(&now, &tm_buf) != NULL) {
        (void)strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
    } else {
        (void)snprintf(stamp, sizeof(stamp), "unknown-time");
    }
    (void)fprintf(fp, "%s status=%s remote=%s bytes=%lld detail=%s\n",
                  stamp, status, (remote != NULL && remote[0] != '\0') ? remote : "-",
                  (long long)bytes, (detail != NULL && detail[0] != '\0') ? detail : "-");
    (void)fclose(fp);
}

static const char *status_text(int code) {
    switch (code) {
        case 400: return "Bad Request";
        case 403: return "Forbidden";
        case 409: return "Conflict";
        case 411: return "Length Required";
        case 500: return "Internal Server Error";
        case 503: return "Service Unavailable";
        default:  return "Error";
    }
}

/* CGI failures must still exit 0 so the server honours our Status header.
 * Flush explicitly: bozohttpd's output-forwarding child only sees EOF (and
 * therefore only finishes the HTTP response) once this process exits, so the
 * bytes must be pushed out before we return. */
static int cgi_fail(int code, const char *reason) {
    printf("Status: %d %s\r\n", code, status_text(code));
    printf("Content-Type: text/plain; charset=utf-8\r\n\r\n");
    printf("ERROR: %s\r\n", reason);
    (void)fflush(stdout);
    log_event("ERROR", g_written, reason);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Small parsing helpers                                               */
/* ------------------------------------------------------------------ */

static const char *ci_find(const char *haystack, const char *needle) {
    size_t needle_len = strlen(needle);
    const char *p = NULL;

    if (needle_len == 0) {
        return haystack;
    }
    for (p = haystack; *p != '\0'; p++) {
        size_t i = 0;
        while (i < needle_len &&
               tolower((unsigned char)p[i]) == tolower((unsigned char)needle[i])) {
            i++;
        }
        if (i == needle_len) {
            return p;
        }
    }
    return NULL;
}

/* Extract the multipart boundary token without its leading "--". */
static int extract_boundary(const char *content_type, char *out, size_t out_size) {
    const char *p = ci_find(content_type, "boundary=");
    int quoted = 0;
    size_t n = 0;

    if (p == NULL) {
        return -1;
    }
    p += strlen("boundary=");
    while (*p == ' ' || *p == '\t') {
        p++;
    }
    if (*p == '"') {
        quoted = 1;
        p++;
    }
    while (*p != '\0' && n + 1 < out_size) {
        unsigned char c = (unsigned char)*p;
        if (quoted) {
            if (*p == '"') {
                break;
            }
        } else if (*p == ';' || *p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
            break;
        }
        if (c < 0x21 || c > 0x7e) {
            return -1;          /* Boundary must be printable ASCII. */
        }
        out[n++] = (char)c;
        p++;
    }
    out[n] = '\0';
    if (n == 0 || n > MAX_BOUNDARY) {
        return -1;
    }
    return 0;
}

/* Return 1 when a usable filename was parsed, 0 when absent, -1 on error. */
static int parse_filename(const char *line, char *out, size_t out_size) {
    const char *p = ci_find(line, "filename=");
    size_t n = 0;

    if (p == NULL) {
        return 0;
    }
    p += strlen("filename=");
    while (*p == ' ' || *p == '\t') {
        p++;
    }
    if (*p == '"') {
        p++;
        while (*p != '\0' && *p != '"') {
            if (n + 1 >= out_size) {
                return -1;
            }
            out[n++] = *p++;
        }
        if (*p != '"') {
            return -1;
        }
    } else {
        while (*p != '\0' && *p != ';' && *p != ' ' && *p != '\t' && *p != '\r') {
            if (n + 1 >= out_size) {
                return -1;
            }
            out[n++] = *p++;
        }
    }
    out[n] = '\0';
    return n > 0 ? 1 : -1;
}

/* Is BYTE a UTF-8 continuation byte (0x80..0xBF)? */
static int is_utf8_cont(unsigned char byte) {
    return (byte & 0xc0) == 0x80;
}

/*
 * Strict UTF-8 validation of exactly N bytes.
 *
 * This is a deliberate byte-for-byte mirror of valid_utf8_bytes() in
 * src/manage.c (v1.0.4).  The two CGIs are independent static binaries, so
 * the validator is duplicated at source level rather than shared at link
 * time; manage.c is left untouched so its published SHA-256 does not move.
 * Keep the two functions in sync when either policy changes.
 *
 * We do not merely allow bytes >= 0x80: every sequence is checked against
 * the RFC 3629 rules so that a malformed byte string cannot smuggle an
 * ASCII separator or a traversal component past the checks below.
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
 * Filename policy (v1.0.6).  All pre-v1.0.6 barriers are kept: absolute
 * paths, any path separator, ".." (as a substring, as before), the single
 * "." name, control bytes and names over MAX_FILENAME bytes are rejected.
 * The final UTF-8 check also admits printable ASCII (0x20-0x7E, including
 * spaces and symbols) and well-formed multibyte characters, aligning upload
 * names with manage.c's folder names.  Unlike folders, a leading dot is
 * allowed so hidden files such as .gitignore can still be uploaded; only
 * "." and ".." are forbidden.
 */
static int valid_filename(const char *name) {
    size_t n = 0;

    if (name == NULL) {
        return 0;
    }
    n = strlen(name);
    if (n == 0 || n > MAX_FILENAME) {
        return 0;
    }
    if (name[0] == '/' || name[0] == '\\') {
        return 0;               /* Absolute paths are rejected, not stripped. */
    }
    if (strchr(name, '/') != NULL || strchr(name, '\\') != NULL) {
        return 0;               /* No separators anywhere (defence in depth). */
    }
    if (strstr(name, "..") != NULL) {
        return 0;               /* Unchanged from v1.0.5: any ".." substring. */
    }
    if (strcmp(name, ".") == 0) {
        return 0;
    }
    return valid_utf8_bytes(name, n);
}

/* ------------------------------------------------------------------ */
/* Buffered stdin reader                                               */
/* ------------------------------------------------------------------ */

static int io_fill(io_t *io) {
    size_t keep = io->len - io->pos;

    if (keep > 0) {
        memmove(io->data, io->data + io->pos, keep);
    }
    io->pos = 0;
    io->len = keep;
    if (io->eof) {
        return (int)keep;
    }
    for (;;) {
        ssize_t got = read(STDIN_FILENO, io->data + io->len, IO_BUFSZ - io->len);
        if (got > 0) {
            io->len += (size_t)got;
            return (int)io->len;
        }
        if (got == 0) {
            io->eof = 1;
            return (int)io->len;
        }
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }
}

static int io_ensure(io_t *io, size_t want) {
    while (io->len - io->pos < want && !io->eof) {
        if (io_fill(io) < 0) {
            return -1;
        }
    }
    return (io->len - io->pos >= want) ? 1 : 0;
}

/* 1 = line read, 0 = clean EOF, -1 = line too long. */
static int io_read_line(io_t *io, char *dst, size_t dst_size) {
    size_t n = 0;

    for (;;) {
        unsigned char c = 0;
        if (io->pos >= io->len) {
            if (io_fill(io) <= 0) {
                return 0;
            }
        }
        c = io->data[io->pos++];
        if (c == '\n') {
            if (n > 0 && dst[n - 1] == '\r') {
                n--;
            }
            dst[n] = '\0';
            return 1;
        }
        if (n + 1 >= dst_size) {
            return -1;
        }
        dst[n++] = (char)c;
    }
}

static const unsigned char *mem_find(const unsigned char *hay, size_t hay_len,
                                     const unsigned char *needle, size_t needle_len) {
    size_t i = 0;

    if (needle_len == 0 || hay_len < needle_len) {
        return NULL;
    }
    for (i = 0; i + needle_len <= hay_len; i++) {
        if (hay[i] == needle[0] && memcmp(hay + i, needle, needle_len) == 0) {
            return hay + i;
        }
    }
    return NULL;
}

static int write_all(int fd, const unsigned char *buf, size_t len) {
    size_t done = 0;

    if (fd < 0) {
        return 0;               /* Discard mode for non-file parts. */
    }
    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);
        if (n > 0) {
            done += (size_t)n;
            g_written += (off_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

/*
 * Stream one part body to fd until the "\r\n--BOUNDARY" delimiter.
 * All but the last (delimiter_len - 1) bytes of each buffer are flushed in
 * one write; the small carry guarantees a boundary split across reads is
 * still detected. The file is never buffered in full.
 */
static int stream_body(io_t *io, int fd, const unsigned char *delim, size_t delim_len) {
    size_t carry = delim_len - 1;

    for (;;) {
        size_t avail = io->len - io->pos;
        const unsigned char *hit = mem_find(io->data + io->pos, avail, delim, delim_len);

        if (hit != NULL) {
            if (write_all(fd, io->data + io->pos,
                          (size_t)(hit - (io->data + io->pos))) < 0) {
                return BODY_ERR;
            }
            io->pos = (size_t)(hit - io->data) + delim_len;

            {
                int enough = io_ensure(io, 2);
                unsigned char c0 = 0;
                unsigned char c1 = 0;
                if (enough < 0) {
                    return BODY_ERR;
                }
                if (enough == 0) {
                    return BODY_END;   /* Some clients omit the final CRLF. */
                }
                c0 = io->data[io->pos];
                c1 = io->data[io->pos + 1];
                if (c0 == '-' && c1 == '-') {
                    io->pos += 2;
                    if (io_ensure(io, 2) == 1 &&
                        io->data[io->pos] == '\r' && io->data[io->pos + 1] == '\n') {
                        io->pos += 2;
                    }
                    return BODY_END;
                }
                if (c0 == '\r' && c1 == '\n') {
                    io->pos += 2;
                    return BODY_NEXT;
                }
                /* False positive inside file data: emit delim and rescan. */
                if (write_all(fd, delim, delim_len) < 0) {
                    return BODY_ERR;
                }
                continue;
            }
        }

        if (avail > carry) {
            size_t flush = avail - carry;
            if (write_all(fd, io->data + io->pos, flush) < 0) {
                return BODY_ERR;
            }
            io->pos += flush;
        }
        {
            size_t before = io->len - io->pos;
            if (io_fill(io) < 0) {
                return BODY_ERR;
            }
            if (io->len == before && io->eof) {
                if (write_all(fd, io->data + io->pos, io->len - io->pos) < 0) {
                    return BODY_ERR;
                }
                io->pos = io->len;
                return BODY_TRUNC;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Safe destination creation                                           */
/* ------------------------------------------------------------------ */

static int safe_open(const char *dir, const char *name, char *out_path,
                     size_t out_size, int *err) {
    char stem[MAX_FILENAME + 1];
    char ext[MAX_FILENAME + 1];
    size_t name_len = strlen(name);
    size_t dot = name_len;
    size_t i = 0;
    int attempt = 0;
    int flags = O_WRONLY | O_CREAT | O_EXCL;

#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    stem[0] = '\0';
    ext[0] = '\0';
    for (i = 1; i < name_len; i++) {
        if (name[i] == '.') {
            dot = i;            /* Last dot that is not the first character. */
        }
    }
    if (dot < name_len) {
        (void)snprintf(stem, sizeof(stem), "%.*s", (int)dot, name);
        (void)snprintf(ext, sizeof(ext), "%s", name + dot);
    } else {
        (void)snprintf(stem, sizeof(stem), "%s", name);
    }

    for (attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        int fd = -1;
        if (attempt == 0) {
            (void)snprintf(out_path, out_size, "%s/%s", dir, name);
        } else {
            (void)snprintf(out_path, out_size, "%s/%s.%d%s", dir, stem, attempt, ext);
        }
        fd = open(out_path, flags, 0644);
        if (fd >= 0) {
            return fd;
        }
        if (errno == EEXIST) {
            continue;
        }
        *err = errno;
        return -1;
    }
    *err = EEXIST;
    return -1;
}

/*
 * NOTE (v1.0.5 bugfix): there is deliberately NO "drain stdin to EOF" step.
 *
 * bozohttpd's cgi-bozo.c hands a CGI ONE AF_UNIX socketpair as both stdin and
 * stdout (dup2(sv[1], 0) and dup2(sv[1], 1)).  The parent writes the request
 * body into sv[0] and exits; a separate output-forwarding child keeps sv[0]
 * open and reads our response from it until EOF.  Consequently stdin can
 * never report EOF until THIS process exits.  A read-to-EOF loop placed
 * before the response (the old drain_stdin()) is a circular wait:
 *
 *     CGI waits for stdin EOF  ->  forwarder waits for CGI stdout bytes
 *     ->  neither happens  ->  client times out, CGI is stuck, lock leaks.
 *
 * The multipart parser already consumed every body byte through the closing
 * boundary, so there is nothing left to drain.  Any non-standard trailing
 * bytes are simply discarded with the socketpair when we exit.  Do not
 * reintroduce a blocking stdin read here.  See CHANGELOG v1.0.5.
 */

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

int main(void) {
    char share_dir[PATH_MAX];
    char state_dir[PATH_MAX];
    const char *env_value = NULL;
    const char *content_length_text = NULL;
    const char *content_type = NULL;
    char *end_ptr = NULL;
    long long length_value = 0;
    off_t content_length = 0;
    char boundary[MAX_BOUNDARY + 1];
    char delim[MAX_BOUNDARY + 8];
    char first_delim[MAX_BOUNDARY + 8];
    size_t delim_len = 0;
    io_t io;
    char line[MAX_LINE];
    int phase = BODY_NEXT;
    int saved_files = 0;
    int rc = 0;

    (void)umask(0022);
    memset(&io, 0, sizeof(io));
    memset(boundary, 0, sizeof(boundary));
    memset(delim, 0, sizeof(delim));
    memset(first_delim, 0, sizeof(first_delim));
    memset(line, 0, sizeof(line));

    env_value = getenv("TC_SHARE_DIR");
    (void)snprintf(share_dir, sizeof(share_dir), "%s",
                   (env_value != NULL && env_value[0] != '\0') ? env_value : DEFAULT_SHARE_DIR);
    env_value = getenv("TC_STATE_DIR");
    (void)snprintf(state_dir, sizeof(state_dir), "%s",
                   (env_value != NULL && env_value[0] != '\0') ? env_value : DEFAULT_STATE_DIR);
    (void)snprintf(g_lock_path, sizeof(g_lock_path), "%s/%s", state_dir, LOCK_NAME);

    (void)signal(SIGINT, on_fatal_signal);
    (void)signal(SIGTERM, on_fatal_signal);
    (void)signal(SIGHUP, on_fatal_signal);
    /* A client that disconnects mid-upload makes a later write to stdout
     * raise SIGPIPE.  Route it through the same handler so the O_EXCL lock is
     * released instead of being left behind by a default-action termination
     * (atexit handlers do NOT run on SIGPIPE). */
    (void)signal(SIGPIPE, on_fatal_signal);
    (void)atexit(cleanup_lock);

    content_length_text = getenv("CONTENT_LENGTH");
    if (content_length_text == NULL || content_length_text[0] == '\0') {
        return cgi_fail(411, "CONTENT_LENGTH is missing");
    }
    errno = 0;
    length_value = strtoll(content_length_text, &end_ptr, 10);
    if (errno != 0 || end_ptr == content_length_text || *end_ptr != '\0' || length_value <= 0) {
        return cgi_fail(400, "invalid CONTENT_LENGTH");
    }
    content_length = (off_t)length_value;

    content_type = getenv("CONTENT_TYPE");
    if (content_type == NULL || ci_find(content_type, "multipart/form-data") != content_type) {
        return cgi_fail(400, "expected multipart/form-data");
    }
    if (extract_boundary(content_type, boundary, sizeof(boundary)) < 0) {
        return cgi_fail(400, "multipart boundary is missing or invalid");
    }
    (void)snprintf(delim, sizeof(delim), "\r\n--%s", boundary);
    (void)snprintf(first_delim, sizeof(first_delim), "--%s", boundary);
    delim_len = strlen(delim);

    /* Single-upload concurrency lock; no flock() on this old kernel. */
    g_lock_fd = open(g_lock_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (g_lock_fd < 0) {
        if (errno == EEXIST) {
            return cgi_fail(503, "another upload is already in progress");
        }
        return cgi_fail(500, "cannot create upload lock in state directory");
    }
    {
        char pid_buf[32];
        int pid_len = snprintf(pid_buf, sizeof(pid_buf), "%ld\n", (long)getpid());
        if (pid_len > 0) {
            (void)write(g_lock_fd, pid_buf, (size_t)pid_len);
        }
    }

    rc = io_read_line(&io, line, sizeof(line));
    if (rc <= 0 || strcmp(line, first_delim) != 0) {
        return cgi_fail(400, "invalid initial multipart boundary");
    }

    while (phase == BODY_NEXT) {
        char raw_name[MAX_FILENAME + 1];
        int have_file = 0;
        int fd = -1;
        char out_path[PATH_MAX];
        off_t file_start = g_written;
        int body_rc = BODY_ERR;
        int open_err = 0;

        raw_name[0] = '\0';
        out_path[0] = '\0';

        for (;;) {
            rc = io_read_line(&io, line, sizeof(line));
            if (rc <= 0) {
                if (fd >= 0) {
                    (void)close(fd);
                }
                return cgi_fail(400, "truncated part headers");
            }
            if (line[0] == '\0') {
                break;             /* Empty line terminates part headers. */
            }
            {
                int parsed = parse_filename(line, raw_name, sizeof(raw_name));
                if (parsed < 0) {
                    return cgi_fail(400, "malformed Content-Disposition header");
                }
                if (parsed == 1) {
                    have_file = 1;
                }
            }
        }

        if (have_file) {
            const char *base = raw_name;
            /* Reject traversal in the RAW header value before reducing it to
             * a basename: previously "../evil.txt" was silently accepted as
             * "evil.txt" (safe but inconsistent with the documented policy).
             * Legitimate browsers only ever send a basename here. */
            if (strchr(raw_name, '/') != NULL || strchr(raw_name, '\\') != NULL ||
                strstr(raw_name, "..") != NULL) {
                return cgi_fail(400, "filename rejected by security policy");
            }
            if (!valid_filename(base)) {
                return cgi_fail(400, "filename rejected by security policy");
            }
            fd = safe_open(share_dir, base, out_path, sizeof(out_path), &open_err);
            if (fd < 0) {
                if (open_err == EEXIST) {
                    return cgi_fail(409, "cannot allocate a free filename");
                }
                return cgi_fail(500, "cannot create destination file");
            }
        }

        body_rc = stream_body(&io, fd, (const unsigned char *)delim, delim_len);
        if (fd >= 0) {
            if (close(fd) < 0) {
                (void)unlink(out_path);
                return cgi_fail(500, "failed to close destination file");
            }
        }
        if (body_rc == BODY_ERR) {
            if (fd >= 0) {
                (void)unlink(out_path);
            }
            return cgi_fail(500, "failed while writing destination file");
        }
        if (body_rc == BODY_TRUNC) {
            if (fd >= 0) {
                (void)unlink(out_path);
            }
            return cgi_fail(400, "request body ended before closing boundary");
        }
        if (fd >= 0) {
            saved_files++;
            log_event("OK", g_written - file_start, out_path);
        }
        phase = body_rc;          /* BODY_END terminates, BODY_NEXT continues. */
    }

    (void)content_length;         /* Kept for diagnostics and future limits. */

    /* Emit a complete CGI response immediately (see the note above: reading
     * stdin to EOF here would deadlock against bozohttpd).  Status: 200 matches
     * cgi_fail()'s explicit status line; fflush() pushes the bytes out before
     * we return, and cleanup_lock()/atexit() release the O_EXCL lock on the
     * normal exit path that the forwarder is waiting for. */
    printf("Status: 200 OK\r\n");
    printf("Content-Type: text/plain; charset=utf-8\r\n\r\n");
    printf("OK files=%d bytes=%lld\r\n", saved_files, (long long)g_written);
    (void)fflush(stdout);
    cleanup_lock();
    return 0;
}
