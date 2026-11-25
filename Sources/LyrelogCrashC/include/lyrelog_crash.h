// The part of Lyrelog's crash reporter that runs while the app crashes: C, because a signal
// handler may only call async-signal-safe functions (no allocation, no locks, no Swift runtime).
// CrashReporter.swift installs it and reads what it wrote on the next launch.
#ifndef LYRELOG_CRASH_H
#define LYRELOG_CRASH_H

#include <stdbool.h>

/// Opens the two files (truncated), records the images loaded and those loaded later, and installs
/// the signal handlers, keeping the ones before to call after. False when a file can't be opened.
bool lyrelog_crash_install(const char *report_path, const char *images_path);

/// Text written into the report if the app crashes next (an uncaught Objective-C exception's name
/// and reason, set just before it aborts). Called from normal code, never from the handler.
void lyrelog_crash_note(const char *text);

/// The return addresses an uncaught Objective-C exception was thrown from (its
/// callStackReturnAddresses), copied before the app aborts: the report shows where it was thrown
/// instead of the abort. Called from normal code.
void lyrelog_crash_note_stack(const unsigned long long *addresses, int count);

/// The crash that follows within `seconds` was already reported another way (a wrapper SDK's
/// fatal JavaScript error, sent before React Native aborts): the handler writes nothing for it,
/// and still hands the signal on.
void lyrelog_crash_already_reported(int seconds);

/// Gives the calling thread an alternate signal stack, so a stack overflow on it is reported.
/// Called on the main thread (sigaltstack is per thread; most overflows happen there).
void lyrelog_crash_alternate_stack(void);

#endif
