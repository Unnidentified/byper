//
// install_helper.c
// Privileged install helper for the byper menu bar companion app.
//
// Executed as root via AuthorizationExecuteWithPrivileges (the admin dialog is
// attributed to byper and offers Touch ID). A dedicated helper keeps /bin/sh
// out of the authorization request — `do shell script ... with administrator
// privileges` routes through /bin/sh, so macOS shows "a script started by
// bash" instead of naming byper.
//
// Usage: byper-installer <project .app bundle> <project CLI binary>
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 || geteuid() != 0) return 2;

    char cmd[8192];
    int n = snprintf(cmd, sizeof(cmd),
        "rm -rf /Applications/byper.app && "
        "cp -R '%s' /Applications/byper.app && "
        "chown -R root:wheel /Applications/byper.app && "
        "chmod 4755 /Applications/byper.app/Contents/Resources/byper && "
        "cp -f '%s' /usr/local/bin/byper && "
        "chown root:wheel /usr/local/bin/byper && "
        "chmod 4755 /usr/local/bin/byper && "
        "killall byper 2>/dev/null; "
        "sleep 1; "
        "open /Applications/byper.app",
        argv[1], argv[2]);
    if (n <= 0 || n >= (int)sizeof(cmd)) return 2;

    return system(cmd) == 0 ? 0 : 1;
}
