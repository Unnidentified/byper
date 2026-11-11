#ifndef SESSION_H
#define SESSION_H

#include <stdbool.h>

typedef struct SessionLog SessionLog;

// Starts a session log on the settings owner's Desktop, named the way the app
// names it: byper-session-<yyyyMMdd-HHmmss>.csv. Returns NULL when the file
// cannot be created.
SessionLog *session_log_start(void);

// Appends one sample row and flushes it, so the file is readable while the log
// is still running.
void session_log_sample(SessionLog *log);

// Writes the summary footer and closes the file.
void session_log_stop(SessionLog *log);

const char *session_log_path(const SessionLog *log);
int session_log_samples(const SessionLog *log);

#endif // SESSION_H
