//
// install_helper.c
// Privileged install helper for the byper menu bar companion app.
//
// Executed as root via AuthorizationExecuteWithPrivileges (the admin dialog is
// attributed to byper and offers Touch ID). A dedicated helper keeps /bin/sh
// out of the authorization request, `do shell script ... with administrator
// privileges` routes through /bin/sh, so macOS shows "a script started by
// bash" instead of naming byper.
//
// Usage: byper-installer <project .app bundle> <project CLI binary>
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Write a single-quoted shell literal of s into out (capacity outsz). Embedded
// single quotes become '\''. Returns bytes written (excluding NUL), or -1 if
// it does not fit. The caller's paths must never reach the shell raw: a quote
// in a path used to break out of the single-quoted cp argument and run arbitrary
// commands as root.
static long shell_quote(char *out, size_t outsz, const char *s) {
    size_t used = 0;
    #define PUT(c) do { if (used + 1 >= outsz) return -1; out[used++] = (char)(c); } while (0)
    PUT('\'');
    for (const char *p = s; *p; p++) {
        if (*p == '\'') {
            PUT('\''); PUT('\\'); PUT('\''); PUT('\'');
        } else {
            PUT(*p);
        }
    }
    PUT('\'');
    out[used] = '\0';
    return (long)used;
    #undef PUT
}

int main(int argc, char **argv) {
    if (argc != 3 || geteuid() != 0) return 2;

    char app_q[4096], cli_q[4096];
    if (shell_quote(app_q, sizeof(app_q), argv[1]) < 0) return 2;
    if (shell_quote(cli_q, sizeof(cli_q), argv[2]) < 0) return 2;

    char cmd[16384];
    int n = snprintf(cmd, sizeof(cmd),
        "rm -rf /Applications/byper.app && "
        "cp -R %s /Applications/byper.app && "
        "chown -R root:wheel /Applications/byper.app && "
        "chmod 4755 /Applications/byper.app/Contents/Resources/byper && "
        "cp -f %s /usr/local/bin/byper && "
        "chown root:wheel /usr/local/bin/byper && "
        "chmod 4755 /usr/local/bin/byper && "
        "killall byper 2>/dev/null; "
        "sleep 1; "
        "open /Applications/byper.app",
        app_q, cli_q);
    if (n <= 0 || n >= (int)sizeof(cmd)) return 2;

    return system(cmd) == 0 ? 0 : 1;
}