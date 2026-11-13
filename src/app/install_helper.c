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
// Every step runs as an absolute-path argv with a fixed, sanitized environment
// and no shell. AuthorizationExecuteWithPrivileges hands the tool the caller's
// environment, so a shell here would resolve rm/cp/chown through the caller's
// PATH (root code execution via a planted binary) and interpolate the paths.
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/wait.h>

static char *const kEnv[] = {
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME=/var/root",
    NULL
};

// Run one absolute-path command with the sanitized environment, detached stdio.
// Returns the child's exit status (0 on success), or 1 on spawn/wait failure.
static int run(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) {
            dup2(dn, STDIN_FILENO);
            dup2(dn, STDOUT_FILENO);
            dup2(dn, STDERR_FILENO);
            if (dn > STDERR_FILENO) close(dn);
        }
        execve(argv[0], argv, kEnv);
        _exit(127);
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

int main(int argc, char **argv) {
    if (argc != 3 || geteuid() != 0) return 2;
    char *app = argv[1];
    char *cli = argv[2];

    // The install steps, chained like the old "&&" string: stop on the first
    // failure. Paths are argv elements, so spaces/quotes/metacharacters in them
    // are inert.
    char *const rm_app[]      = { "/bin/rm", "-rf", "/Applications/byper.app", NULL };
    char *const cp_app[]      = { "/bin/cp", "-R", app, "/Applications/byper.app", NULL };
    char *const chown_app[]   = { "/usr/sbin/chown", "-R", "root:wheel", "/Applications/byper.app", NULL };
    char *const chmod_app[]   = { "/bin/chmod", "4755", "/Applications/byper.app/Contents/Resources/byper", NULL };
    char *const cp_cli[]      = { "/bin/cp", "-f", cli, "/usr/local/bin/byper", NULL };
    char *const chown_cli[]   = { "/usr/sbin/chown", "root:wheel", "/usr/local/bin/byper", NULL };
    char *const chmod_cli[]   = { "/bin/chmod", "4755", "/usr/local/bin/byper", NULL };

    if (run(rm_app) != 0) return 1;
    if (run(cp_app) != 0) return 1;
    if (run(chown_app) != 0) return 1;
    if (run(chmod_app) != 0) return 1;
    if (run(cp_cli) != 0) return 1;
    if (run(chown_cli) != 0) return 1;
    if (run(chmod_cli) != 0) return 1;

    // Best-effort tail, like the old "; " separators: restart the app even if
    // killall finds nothing.
    char *const killall[] = { "/usr/bin/killall", "byper", NULL };
    char *const sleep1[]  = { "/bin/sleep", "1", NULL };
    char *const open_app[] = { "/usr/bin/open", "/Applications/byper.app", NULL };
    (void)run(killall);
    (void)run(sleep1);
    (void)run(open_app);
    return 0;
}