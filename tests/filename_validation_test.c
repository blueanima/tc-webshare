/*
 * filename_validation_test.c - local-only proof of the v1.0.6 upload
 * filename policy.  It includes src/upload.c with main() renamed so the
 * static valid_filename() can be exercised on the host without a CGI setup.
 *
 * Usage:
 *   cc -Wall -Wextra -O0 -o /tmp/tc_filename_test tests/filename_validation_test.c
 *   /tmp/tc_filename_test
 * Exit 0 = all cases passed, 1 = at least one policy violation.
 *
 * Copyright (C) 2026 tc-webshare contributors - SPDX-License-Identifier: GPL-3.0-or-later
 */

#define main tc_upload_main_under_test
#include "../src/upload.c"
#undef main

#include <stdio.h>
#include <string.h>

typedef struct {
    const char *label;
    const char *name;
    int expected;               /* 1 = accepted, 0 = rejected by policy. */
} case_t;

static const case_t kCases[] = {
    /* Chinese, symbols, emoji and hidden files must be accepted now. */
    {"Chinese docx", "内网算力统筹与工作思路.docx", 1},
    {"Chinese + symbols", "项目计划（最终版）- v2!.docx", 1},
    {"Chinese + ASCII symbol", "中文+符号!@#.md", 1},
    {"emoji (4-byte UTF-8)", "报告\360\237\230\200.md", 1},
    {"2-byte UTF-8", "caf\303\251.txt", 1},
    {"3-byte UTF-8", "\345\256\203\346\234\254.txt", 1},
    {"hidden file stays valid", ".gitignore", 1},
    {"printable ASCII symbols", "a !#$%&'()+,;=[]@^~{}-.txt", 1},
    {"single dot in name", "report.v2.txt", 1},
    /* Every pre-v1.0.6 barrier must still be enforced. */
    {"empty name", "", 0},
    {"single dot", ".", 0},
    {"double dot", "..", 0},
    {"dotdot substring", "a..b", 0},
    {"absolute POSIX path", "/etc/passwd", 0},
    {"embedded slash", "dir/file.txt", 0},
    {"embedded backslash", "dir\\file.txt", 0},
    {"Windows traversal", "..\\evil.txt", 0},
    {"C0 control", "bad\001name.txt", 0},
    {"DEL byte", "bad\177name.txt", 0},
    {"C1 control (U+0080)", "bad\302\200name.txt", 0},
    /* Strict RFC 3629: no malformed sequence may be accepted. */
    {"stray continuation", "bad\200name.txt", 0},
    {"truncated 2-byte", "bad\303", 0},
    {"bad continuation", "bad\303\050name.txt", 0},
    {"overlong 2-byte (C0 AF)", "bad\300\257name.txt", 0},
    {"overlong 3-byte (E0 80 AF)", "bad\340\200\257name.txt", 0},
    {"UTF-16 surrogate (ED A0 80)", "bad\355\240\200name.txt", 0},
    {"overlong 4-byte (F0 80 80 AF)", "bad\360\200\200\257name.txt", 0},
    {"above U+10FFFF (F4 90 80 80)", "bad\364\220\200\200name.txt", 0},
    {"invalid lead F5", "bad\365\200\200\200name.txt", 0},
    {"invalid byte FF", "bad\377name.txt", 0}
};

int main(void) {
    char long_name[MAX_FILENAME + 2];
    size_t i = 0;
    int failures = 0;

    for (i = 0; i < sizeof(kCases) / sizeof(kCases[0]); i++) {
        int got = valid_filename(kCases[i].name);
        if (got != kCases[i].expected) {
            printf("FAIL %-30s expected=%d got=%d\n",
                   kCases[i].label, kCases[i].expected, got);
            failures++;
        } else {
            printf("PASS %-30s -> %d\n", kCases[i].label, got);
        }
    }

    memset(long_name, 'a', sizeof(long_name));
    long_name[MAX_FILENAME] = '\0';
    if (valid_filename(long_name) != 1) {
        printf("FAIL %-30s expected=1 got=0\n", "exactly 200 bytes");
        failures++;
    } else {
        printf("PASS %-30s -> 1\n", "exactly 200 bytes");
    }
    long_name[MAX_FILENAME] = 'a';
    long_name[MAX_FILENAME + 1] = '\0';
    if (valid_filename(long_name) != 0) {
        printf("FAIL %-30s expected=0 got=1\n", "201 bytes");
        failures++;
    } else {
        printf("PASS %-30s -> 0\n", "201 bytes");
    }

    printf("VERDICT: %s (%d failure(s))\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
