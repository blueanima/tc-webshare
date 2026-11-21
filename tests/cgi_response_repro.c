/*
 * cgi_response_repro.c - native harness proving the v1.0.5 upload hang bug.
 *
 * It reproduces bozohttpd's CGI I/O topology from cgi-bozo.c exactly:
 *
 *   socketpair(AF_UNIX, SOCK_STREAM, 0, sv)
 *   CGI child   : dup2(sv[1], 0); dup2(sv[1], 1)   <- ONE socket for in+out
 *   input parent: writes CONTENT_LENGTH body bytes to sv[0], then exits
 *   output child: keeps sv[0] open, reads the CGI response until EOF, then
 *                 forwards it to the client (finish_cgi_output())
 *
 * Because the output child holds sv[0] open, stdin on the CGI side can never
 * report EOF until the CGI itself exits.  A CGI that reads stdin to EOF after
 * parsing the multipart body therefore deadlocks against its own response.
 *
 * Usage:  cgi_response_repro /path/to/upload.cgi
 * Exit 0 = response complete, CGI exited, lock released (PASS).
 * Exit 1 = hang / incomplete response / leaked lock (BUG REPRODUCED).
 * Exit 2 = harness error.
 *
 * Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
 */

#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define BOUNDARY "BOUNDARY123"
#define FILE_CONTENT "hello tc-webshare\n"
#define EXPECTED_BYTES (sizeof(FILE_CONTENT) - 1)
#define POLL_INTERVAL_US 20000

static int g_timeout_ms = 4000;

static void diag(const char *msg) {
    fprintf(stderr, "repro: %s: %s\n", msg, strerror(errno));
}

static long now_ms(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return 0;
    }
    return (long)tv.tv_sec * 1000L + (long)tv.tv_usec / 1000L;
}

static int path_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int write_all_fd(int fd, const char *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

/* Simulates finish_cgi_output(): read sv[0] to EOF, save raw response bytes,
 * then create a marker so the harness knows forwarding completed. */
static void run_output_child(int sv0, const char *resp_path, const char *marker) {
    char buf[4096];
    int resp_fd = -1;
    int mark_fd = -1;

    /* The caller already closed sv[1] in this child. */
    resp_fd = open(resp_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (resp_fd < 0) {
        _exit(3);
    }
    for (;;) {
        ssize_t n = read(sv0, buf, sizeof(buf));
        if (n > 0) {
            if (write_all_fd(resp_fd, buf, (size_t)n) < 0) {
                break;
            }
        } else if (n == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    (void)close(resp_fd);
    (void)close(sv0);
    mark_fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (mark_fd >= 0) {
        (void)write_all_fd(mark_fd, "done", 4);
        (void)close(mark_fd);
    }
    _exit(0);
}

int main(int argc, char **argv) {
    char tmpdir[] = "/tmp/tcwebshare_repro_XXXXXX";
    char share_dir[512];
    char state_dir[512];
    char lock_path[560];
    char out_path[560];
    char resp_path[560];
    char marker_path[560];
    char body[1024];
    char clen_str[32];
    char response[8192];
    const char *cgi_path = NULL;
    int sv[2] = {-1, -1};
    pid_t cgi_pid = -1;
    pid_t out_pid = -1;
    int cgi_status = 0;
    int out_status = 0;
    int cgi_reaped = 0;
    int out_reaped = 0;
    int resp_fd = -1;
    int in_fd = -1;
    long deadline = 0;
    int timed_out = 0;
    int ok = 1;
    const char *timeout_env = NULL;
    size_t body_len = 0;
    ssize_t body_written = 0;
    ssize_t resp_len = 0;

    if (argc != 2) {
        fprintf(stderr, "usage: %s /path/to/upload.cgi\n", argv[0]);
        return 2;
    }
    cgi_path = argv[1];
    timeout_env = getenv("REPRO_TIMEOUT_MS");
    if (timeout_env != NULL && timeout_env[0] != '\0') {
        long parsed = strtol(timeout_env, NULL, 10);
        if (parsed > 0) {
            g_timeout_ms = (int)parsed;
        }
    }

    /* PID + time keeps parallel harness runs from colliding. */
    (void)snprintf(tmpdir, sizeof(tmpdir), "/tmp/tcwebshare_repro_%ld_%ld",
                   (long)getpid(), (long)time(NULL));
    if (mkdir(tmpdir, 0700) != 0) {
        diag("mkdir tmpdir");
        return 2;
    }
    (void)snprintf(share_dir, sizeof(share_dir), "%s/share", tmpdir);
    (void)snprintf(state_dir, sizeof(state_dir), "%s/state", tmpdir);
    (void)snprintf(lock_path, sizeof(lock_path), "%s/upload.lock", state_dir);
    (void)snprintf(out_path, sizeof(out_path), "%s/testfile.txt", share_dir);
    (void)snprintf(resp_path, sizeof(resp_path), "%s/response.txt", tmpdir);
    (void)snprintf(marker_path, sizeof(marker_path), "%s/output_done", tmpdir);
    if (mkdir(share_dir, 0700) != 0 || mkdir(state_dir, 0700) != 0) {
        diag("mkdir");
        return 2;
    }

    body_len = (size_t)snprintf(
        body, sizeof(body),
        "--%s\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"testfile.txt\"\r\n"
        "Content-Type: text/plain\r\n"
        "\r\n"
        FILE_CONTENT
        "\r\n--%s--\r\n",
        BOUNDARY, BOUNDARY);
    (void)snprintf(clen_str, sizeof(clen_str), "%lu", (unsigned long)body_len);

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        diag("socketpair");
        return 2;
    }

    /* --- CGI child: same fd setup as bozohttpd ------------------------ */
    cgi_pid = fork();
    if (cgi_pid < 0) {
        diag("fork cgi");
        return 2;
    }
    if (cgi_pid == 0) {
        /* Buffers live in this frame until execve() copies the environment. */
        char env_clen[64];
        char env_ctype[128];
        char env_share[560];
        char env_state[560];
        close(sv[0]);
        if (dup2(sv[1], STDIN_FILENO) < 0 || dup2(sv[1], STDOUT_FILENO) < 0) {
            _exit(4);
        }
        close(sv[1]);
        (void)snprintf(env_clen, sizeof(env_clen), "CONTENT_LENGTH=%s", clen_str);
        (void)snprintf(env_ctype, sizeof(env_ctype),
                       "CONTENT_TYPE=multipart/form-data; boundary=%s", BOUNDARY);
        (void)snprintf(env_share, sizeof(env_share), "TC_SHARE_DIR=%s", share_dir);
        (void)snprintf(env_state, sizeof(env_state), "TC_STATE_DIR=%s", state_dir);
        (void)putenv(env_clen);
        (void)putenv(env_ctype);
        (void)putenv(env_share);
        (void)putenv(env_state);
        (void)putenv("REMOTE_ADDR=127.0.0.1");
        execl(cgi_path, cgi_path, (char *)NULL);
        diag("execl cgi");
        _exit(127);
    }

    /* --- output child: holds sv[0] open while waiting for response ----- */
    out_pid = fork();
    if (out_pid < 0) {
        diag("fork output");
        (void)kill(cgi_pid, SIGKILL);
        return 2;
    }
    if (out_pid == 0) {
        close(sv[1]);
        run_output_child(sv[0], resp_path, marker_path);
        _exit(0); /* unreachable */
    }

    /* --- input parent: write body, then "exit" (close our sv[0]) -------- */
    close(sv[1]);
    body_written = write_all_fd(sv[0], body, body_len);
    if (body_written < 0) {
        diag("write body");
    }
    close(sv[0]);
    sv[0] = -1;

    deadline = now_ms() + g_timeout_ms;
    for (;;) {
        pid_t r = waitpid(cgi_pid, &cgi_status, WNOHANG);
        if (r == cgi_pid) {
            cgi_reaped = 1;
        } else if (r < 0 && errno != EINTR) {
            cgi_reaped = 1; /* treat as done to avoid looping forever */
        }
        r = waitpid(out_pid, &out_status, WNOHANG);
        if (r == out_pid) {
            out_reaped = 1;
        } else if (r < 0 && errno != EINTR) {
            out_reaped = 1;
        }
        if (cgi_reaped && out_reaped && path_exists(marker_path)) {
            break;
        }
        if (now_ms() >= deadline) {
            timed_out = 1;
            break;
        }
        usleep(POLL_INTERVAL_US);
    }

    if (timed_out) {
        (void)kill(cgi_pid, SIGKILL);
        (void)kill(out_pid, SIGKILL);
        (void)waitpid(cgi_pid, &cgi_status, 0);
        (void)waitpid(out_pid, &out_status, 0);
        cgi_reaped = 0;
        out_reaped = 0;
    }

    response[0] = '\0';
    resp_fd = open(resp_path, O_RDONLY);
    if (resp_fd >= 0) {
        resp_len = read(resp_fd, response, sizeof(response) - 1);
        if (resp_len > 0) {
            response[resp_len] = '\0';
        } else {
            response[0] = '\0';
        }
        close(resp_fd);
    }

    printf("repro result:\n");
    printf("  timed_out        : %s\n", timed_out ? "YES" : "no");
    printf("  cgi_exited       : %s\n", cgi_reaped ? "yes" : "NO");
    printf("  output_forwarded : %s\n", path_exists(marker_path) ? "yes" : "NO");
    printf("  lock_released    : %s\n", path_exists(lock_path) ? "NO" : "yes");
    printf("  response_bytes   : %ld\n", (long)resp_len);
    printf("  response_head    : %.*s\n",
           resp_len > 0 ? (int)(resp_len < 120 ? resp_len : 120) : 0, response);

    if (timed_out) {
        printf("  FAIL: CGI blocked; HTTP response never completed\n");
        ok = 0;
    }
    if (!cgi_reaped) {
        printf("  FAIL: CGI process still alive after deadline\n");
        ok = 0;
    }
    if (!path_exists(marker_path)) {
        printf("  FAIL: output forwarder never saw EOF / marker missing\n");
        ok = 0;
    }
    if (path_exists(lock_path)) {
        printf("  FAIL: upload.lock left behind\n");
        ok = 0;
    }
    if (strstr(response, "Status: 200 OK") == NULL) {
        printf("  FAIL: no Status: 200 OK in response\n");
        ok = 0;
    }
    if (strstr(response, "OK files=1 bytes=") == NULL) {
        printf("  FAIL: no OK body in response\n");
        ok = 0;
    }
    in_fd = open(out_path, O_RDONLY);
    if (in_fd < 0) {
        printf("  FAIL: destination file missing\n");
        ok = 0;
    } else {
        char content[64];
        ssize_t n = read(in_fd, content, sizeof(content) - 1);
        if (n > 0) {
            content[n] = '\0';
        } else {
            content[0] = '\0';
        }
        close(in_fd);
        if (strcmp(content, FILE_CONTENT) != 0 || n != EXPECTED_BYTES) {
            printf("  FAIL: destination content mismatch (%ld bytes)\n", (long)n);
            ok = 0;
        }
    }

    printf("VERDICT: %s\n", ok ? "PASS" : "BUG_REPRODUCED");

    /* Cleanup scratch files. */
    (void)unlink(resp_path);
    (void)unlink(marker_path);
    (void)unlink(out_path);
    (void)unlink(lock_path);
    (void)rmdir(share_dir);
    (void)rmdir(state_dir);
    (void)rmdir(tmpdir);

    return ok ? 0 : 1;
}
