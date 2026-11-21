/*
 * chpasswd_c_test.c - native logic test for manage.c's /chpasswd.cgi path.
 *
 * Includes manage.c with its main() renamed so the static helpers can be
 * exercised directly on the host.  No device, no credentials, no network:
 * all hashing uses throwaway passwords created inside a temporary directory.
 *
 * Run: cc -Wall -Wextra -o /tmp/tc_chpasswd_test tests/chpasswd_c_test.c
 *      /tmp/tc_chpasswd_test
 *
 * macOS crypt() has no "$1$" support, so this host test substitutes a
 * deterministic MD5-crypt-shaped stub (see tc_manage_crypt_stub below) to
 * exercise the file/validation/routing logic.  The device binary uses the
 * real NetBSD libcrypt crypt(), whose md5crypt dispatch is verified from
 * the tc_wb sysroot sources.
 * Copyright (C) 2026 tc-webshare contributors - GPL-3.0-or-later.
 */
#define main tc_manage_unused_main
#define crypt tc_manage_crypt_stub
#include "../src/manage.c"
#undef crypt
#undef main

#include <assert.h>

/* Deterministic "$1$<salt>$<22 chars>" stand-in, sufficient to test hash
 * storage, user preservation and old-password comparison on the host. */
static char stub_out[128];

char *tc_manage_crypt_stub(const char *key, const char *setting) {
    static const char b64[] =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    unsigned long long h = 1469598103934665603ULL;
    char salt[9];
    size_t n = 0;
    size_t i = 0;
    size_t used = 0;

    stub_out[0] = '\0';
    if (key == NULL || setting == NULL || strncmp(setting, "$1$", 3) != 0) {
        return stub_out;
    }
    setting += 3;
    while (*setting != '\0' && *setting != '$' && n < 8) {
        salt[n++] = *setting++;
    }
    salt[n] = '\0';
    for (i = 0; i < n; i++) h = (h ^ (unsigned char)salt[i]) * 1099511628211ULL;
    for (i = 0; key[i] != '\0'; i++) h = (h ^ (unsigned char)key[i]) * 1099511628211ULL;

    used = (size_t)snprintf(stub_out, sizeof(stub_out), "$1$%s$", salt);
    for (i = 0; i < 22 && used + 1 < sizeof(stub_out); i++) {
        stub_out[used++] = b64[(h >> ((i * 3) % 61)) & 0x3f];
    }
    stub_out[used] = '\0';
    return stub_out;
}

static char work_dir[PATH_MAX];

static void make_path(char *dst, size_t size, const char *name) {
    (void)snprintf(dst, size, "%s/%s", work_dir, name);
}

/* Run one CGI invocation and capture the full HTTP response in OUT. */
static void run_case(const char *body, const char *etc_dir,
                     const char *state_dir, const char *remote_user,
                     const char *content_type, char *out, size_t out_size) {
    char body_path[PATH_MAX];
    char out_path[PATH_MAX];
    char len_text[32];
    FILE *fp = NULL;
    size_t n = 0;

    make_path(body_path, sizeof(body_path), "request.body");
    make_path(out_path, sizeof(out_path), "response.txt");
    fp = fopen(body_path, "wb");
    assert(fp != NULL);
    assert(fwrite(body, 1, strlen(body), fp) == strlen(body));
    (void)fclose(fp);

    (void)freopen(body_path, "rb", stdin);
    (void)freopen(out_path, "wb", stdout);

    (void)setenv("TC_ETC_DIR", (etc_dir != NULL) ? etc_dir : "", 1);
    (void)setenv("TC_STATE_DIR", (state_dir != NULL) ? state_dir : "", 1);
    if (remote_user != NULL) {
        (void)setenv("REMOTE_USER", remote_user, 1);
    } else {
        (void)unsetenv("REMOTE_USER");
    }
    (void)setenv("SCRIPT_NAME", "/chpasswd.cgi", 1);
    if (content_type != NULL) {
        (void)setenv("CONTENT_TYPE", content_type, 1);
    } else {
        (void)unsetenv("CONTENT_TYPE");
    }
    (void)snprintf(len_text, sizeof(len_text), "%lu",
                   (unsigned long)strlen(body));
    (void)setenv("CONTENT_LENGTH", len_text, 1);

    (void)action_chpasswd();
    (void)fflush(stdout);

    fp = fopen(out_path, "rb");
    assert(fp != NULL);
    n = fread(out, 1, out_size - 1, fp);
    out[n] = '\0';
    (void)fclose(fp);
}

static void write_file(const char *path, const char *content, mode_t mode) {
    FILE *fp = NULL;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);

    assert(fd >= 0);
    (void)close(fd);
    fp = fopen(path, "wb");
    assert(fp != NULL);
    assert(fwrite(content, 1, strlen(content), fp) == strlen(content));
    (void)fclose(fp);
    assert(chmod(path, mode) == 0);
}

static void read_file(const char *path, char *buf, size_t size) {
    FILE *fp = fopen(path, "rb");
    size_t n = 0;

    assert(fp != NULL);
    n = fread(buf, 1, size - 1, fp);
    buf[n] = '\0';
    (void)fclose(fp);
}

static void assert_mode_0600(const char *path) {
    struct stat sb;
    assert(stat(path, &sb) == 0);
    assert((sb.st_mode & 0777) == 0600);
}

int main(void) {
    char template[PATH_MAX];
    char etc_dir[PATH_MAX];
    char state_dir[PATH_MAX];
    char htpasswd[PATH_MAX];
    char body[1024];
    char out[8192];
    char before[8192];
    char after[8192];
    char *line = NULL;

    (void)snprintf(template, sizeof(template), "/tmp/tc_chpasswd_test.%ld",
                   (long)getpid());
    assert(mkdir(template, 0700) == 0 || errno == EEXIST);
    (void)snprintf(work_dir, sizeof(work_dir), "%s", template);
    (void)snprintf(etc_dir, sizeof(etc_dir), "%s/etc", work_dir);
    (void)snprintf(state_dir, sizeof(state_dir), "%s/state", work_dir);
    assert(mkdir(etc_dir, 0700) == 0);
    assert(mkdir(state_dir, 0700) == 0);
    make_path(htpasswd, sizeof(htpasswd), "etc/htpasswd");

    /* --- 1. valid change: other users kept, 0600, $1$ hash, no plaintext -- */
    write_file(htpasswd, "admin:OLDHASH\nalice:ALICEHASH\n", 0644);
    (void)snprintf(body, sizeof(body), "new_password=Temporary-Test-Value-1");
    run_case(body, etc_dir, NULL, NULL, "application/x-www-form-urlencoded",
             out, sizeof(out));
    assert(strstr(out, "{\"ok\":true}") != NULL);
    read_file(htpasswd, after, sizeof(after));
    assert(strstr(after, "alice:ALICEHASH") != NULL);
    assert(strstr(after, "OLDHASH") == NULL);
    assert(strstr(after, "admin:$1$") != NULL);
    assert(strstr(after, "Temporary-Test-Value-1") == NULL);
    assert_mode_0600(htpasswd);
    fprintf(stderr, "1. valid change / preserve users / 0600 : OK\n");

    /* --- 2. no temp files left behind ---------------------------------- */
    {
        DIR *d = opendir(etc_dir);
        struct dirent *de = NULL;
        int temps = 0;
        assert(d != NULL);
        while ((de = readdir(d)) != NULL) {
            if (strstr(de->d_name, ".htpasswd.tmp.") != NULL) temps++;
        }
        (void)closedir(d);
        assert(temps == 0);
    }
    fprintf(stderr, "2. atomic temp cleanup                  : OK\n");

    /* --- 3. old_password wrong -> 403, file untouched ------------------ */
    read_file(htpasswd, before, sizeof(before));
    (void)snprintf(body, sizeof(body),
                   "new_password=Another-Value-2&old_password=definitely-wrong");
    run_case(body, etc_dir, NULL, NULL, "application/x-www-form-urlencoded",
             out, sizeof(out));
    assert(strstr(out, "Status: 403") != NULL);
    read_file(htpasswd, after, sizeof(after));
    assert(strcmp(before, after) == 0);
    fprintf(stderr, "3. wrong old password -> 403            : OK\n");

    /* --- 4. old_password correct -> 200 -------------------------------- */
    (void)snprintf(body, sizeof(body),
                   "new_password=Another-Value-2&old_password=Temporary-Test-Value-1");
    run_case(body, etc_dir, NULL, NULL, "application/x-www-form-urlencoded",
             out, sizeof(out));
    assert(strstr(out, "{\"ok\":true}") != NULL);
    read_file(htpasswd, after, sizeof(after));
    line = strstr(after, "admin:$1$");
    assert(line != NULL);
    fprintf(stderr, "4. correct old password -> 200          : OK\n");

    /* --- 5. invalid inputs -> 400 -------------------------------------- */
    run_case("new_password=", etc_dir, NULL, NULL,
             "application/x-www-form-urlencoded", out, sizeof(out));
    assert(strstr(out, "Status: 400") != NULL);
    (void)snprintf(body, sizeof(body), "new_password=%s%s",
                   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                   "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "A");
    run_case(body, etc_dir, NULL, NULL,
             "application/x-www-form-urlencoded", out, sizeof(out));
    assert(strstr(out, "Status: 400") != NULL);
    run_case("new_password=line%0Abreak", etc_dir, NULL, NULL,
             "application/x-www-form-urlencoded", out, sizeof(out));
    assert(strstr(out, "Status: 400") != NULL);
    run_case("new_password=abc", etc_dir, NULL, NULL, NULL, out, sizeof(out));
    assert(strstr(out, "Status: 400") != NULL);
    fprintf(stderr, "5. empty/overlong/control/GET -> 400   : OK\n");

    /* --- 6. state-dir fallback (old dispatcher) + REMOTE_USER ---------- */
    write_file(htpasswd, "alice:ALICEHASH\n", 0600);
    (void)snprintf(body, sizeof(body), "new_password=Fallback-Test-Value-3");
    run_case(body, NULL, state_dir, "alice",
             "application/x-www-form-urlencoded", out, sizeof(out));
    assert(strstr(out, "{\"ok\":true}") != NULL);
    read_file(htpasswd, after, sizeof(after));
    assert(strstr(after, "alice:$1$") != NULL);
    assert(strstr(after, "Fallback-Test-Value-3") == NULL);
    fprintf(stderr, "6. TC_STATE_DIR fallback + REMOTE_USER : OK\n");

    /* --- 7. unsafe etc path -> 500, no writes outside temp dir --------- */
    run_case("new_password=something", "/tmp/tc/../etc", NULL, NULL,
             "application/x-www-form-urlencoded", out, sizeof(out));
    assert(strstr(out, "Status: 500") != NULL);
    fprintf(stderr, "7. unsafe etc path -> 500              : OK\n");

    (void)unlink(htpasswd);
    (void)rmdir(etc_dir);
    (void)rmdir(state_dir);
    (void)rmdir(work_dir);
    fprintf(stderr, "ALL CHPASSWD C TESTS PASSED\n");
    return 0;
}
