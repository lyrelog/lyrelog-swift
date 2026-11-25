// Lyrelog's in-process crash reporter (2026-11-25): what the crashed thread was doing, written the
// moment it crashes, so the report is sent on the next launch instead of whenever MetricKit
// delivers it (hours, sometimes). Everything below the handler is async-signal-safe: write(2),
// vm_read_overwrite, sigaction, raise, time. No allocation, no locks, no Objective-C or Swift.
//
// Two files, both opened at install:
//   images: one line per loaded image, written by dyld's callback in normal code:
//           "image <load address hex> <__TEXT size hex> <UUID> <name>"
//   report: written only by the handler:
//           "lyrelog-crash 1" / "signal N" / "code N" / "address hex" / "time unix" /
//           "note text" (optional) / "message text" (a Swift runtime failure's) / "thrown hex"
//           (an uncaught exception's throw site, top first) / "frame hex" (top first), "lr hex" (the link register,
//           after the first frame, when the frame chain doesn't start with it) ... / "end"
// The previous handlers are restored and the signal raised again, so another reporter (Sentry,
// Crashlytics) and the system's own crash report still see the crash.

#include "lyrelog_crash.h"

#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

static int report_fd = -1;
static int images_fd = -1;
static const int signals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP};
#define SIGNAL_COUNT (sizeof(signals) / sizeof(signals[0]))
static struct sigaction previous[SIGNAL_COUNT];
// Which thread is writing the report (0: none). A second thread crashing meanwhile waits for it;
// the same thread crashing again (inside the handler) hands the signal on at once.
static _Atomic uint64_t handling_thread = 0;
static int taken[SIGNAL_COUNT];
// Where libswiftCore keeps the message of a fatalError ("Index out of range"): its
// __DATA,__crash_info section, found when the image loads (Sentry and Crashlytics read it too).
static _Atomic uintptr_t swift_crash_info = 0;
static _Atomic int64_t reported_until = 0; // a crash before this time was already reported
static uint64_t exception_stack[128];
static volatile int exception_stack_count = 0;
static char note[1024];
static volatile size_t note_length = 0;
static char alternate_stack[64 * 1024];
static char main_alternate_stack[64 * 1024];

// MARK: - Writing without allocating

static void put(int fd, const char *text, size_t length) {
    while (length > 0) {
        ssize_t n = write(fd, text, length);
        if (n <= 0) return;
        text += n;
        length -= (size_t)n;
    }
}

static void put_string(int fd, const char *text) { put(fd, text, strlen(text)); }

static void put_hex(int fd, uint64_t value) {
    char buffer[19];
    int i = 18;
    buffer[i] = 0;
    do {
        buffer[--i] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    } while (value != 0 && i > 2);
    buffer[--i] = 'x';
    buffer[--i] = '0';
    put(fd, buffer + i, (size_t)(18 - i));
}

static void put_decimal(int fd, int64_t value) {
    char buffer[24];
    int i = 23;
    buffer[i] = 0;
    int negative = value < 0;
    uint64_t v = negative ? (uint64_t)(-value) : (uint64_t)value;
    do {
        buffer[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v != 0 && i > 1);
    if (negative) buffer[--i] = '-';
    put(fd, buffer + i, (size_t)(23 - i));
}

static void put_line(int fd, const char *key, uint64_t value, int hex) {
    put_string(fd, key);
    put(fd, " ", 1);
    if (hex) put_hex(fd, value); else put_decimal(fd, (int64_t)value);
    put(fd, "\n", 1);
}

// MARK: - Images (normal code: dyld's callback)

static void image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (images_fd < 0 || header == NULL) return;
    if (header->magic != MH_MAGIC_64) return;
    const struct load_command *command = (const struct load_command *)((const char *)header + sizeof(struct mach_header_64));
    uint64_t text_size = 0;
    const uint8_t *uuid = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_TEXT) == 0) text_size = segment->vmsize;
        } else if (command->cmd == LC_UUID) {
            uuid = ((const struct uuid_command *)command)->uuid;
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    if (uuid == NULL || text_size == 0) return;
    Dl_info info;
    const char *name = "?";
    if (dladdr(header, &info) != 0 && info.dli_fname != NULL) {
        const char *slash = strrchr(info.dli_fname, '/');
        name = slash != NULL ? slash + 1 : info.dli_fname;
    }
    if (strcmp(name, "libswiftCore.dylib") == 0) {
        unsigned long size = 0;
        uint8_t *section = getsectiondata((const struct mach_header_64 *)header, "__DATA", "__crash_info", &size);
        if (section != NULL && size >= 16) atomic_store(&swift_crash_info, (uintptr_t)section);
    }
    // One write per line, so lines from images loaded on two threads never interleave.
    char line[512];
    size_t n = 0;
    const char *hex = "0123456789ABCDEF";
    #define ADD(c) do { if (n < sizeof(line) - 1) line[n++] = (c); } while (0)
    const char *prefix = "image ";
    for (const char *p = prefix; *p; p++) ADD(*p);
    uint64_t values[2] = {(uint64_t)(uintptr_t)header, text_size};
    for (int v = 0; v < 2; v++) {
        ADD('0'); ADD('x');
        int started = 0;
        for (int shift = 60; shift >= 0; shift -= 4) {
            int digit = (int)((values[v] >> shift) & 0xf);
            if (digit != 0 || started || shift == 0) { ADD("0123456789abcdef"[digit]); started = 1; }
        }
        ADD(' ');
    }
    for (int b = 0; b < 16; b++) {
        if (b == 4 || b == 6 || b == 8 || b == 10) ADD('-');
        ADD(hex[uuid[b] >> 4]);
        ADD(hex[uuid[b] & 0xf]);
    }
    ADD(' ');
    for (const char *p = name; *p && *p != '\n'; p++) ADD(*p);
    #undef ADD
    line[n++] = '\n';
    put(images_fd, line, n);
}

// MARK: - The handler

static int read_memory(uint64_t address, void *out, vm_size_t length) {
    vm_size_t size = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, length, (vm_address_t)out, &size) == KERN_SUCCESS && size == length;
}

static int readable(uint64_t address, uint64_t out[2]) { return read_memory(address, out, 16); }

// The message of a Swift runtime failure, if libswiftCore left one: its crash_info record is
// { uint64 version; char *message; ... }. Read through vm_read, so a bad pointer can't fault.
static void put_swift_message(int fd) {
    uintptr_t info = atomic_load(&swift_crash_info);
    if (info == 0) return;
    uint64_t record[2];
    if (!read_memory(info, record, sizeof(record)) || record[1] == 0) return;
    char message[512];
    size_t valid = 0; // bytes read, 64 at a time, until the string's end or what can't be read
    while (valid < sizeof(message) && read_memory(record[1] + valid, message + valid, 64)) {
        valid += 64;
        if (memchr(message + valid - 64, 0, 64) != NULL) break;
    }
    size_t end = 0;
    while (end < valid && message[end] != 0) end++;
    if (end == 0) return;
    put_string(fd, "message ");
    for (size_t i = 0; i < end; i++) {
        char c = message[i] == '\n' ? ' ' : message[i];
        put(fd, &c, 1);
    }
    put(fd, "\n", 1);
}

static uint64_t strip(uint64_t address) {
#if defined(__arm64__)
    return address & 0x0000000FFFFFFFFFULL; // pointer authentication bits (arm64e)
#else
    return address;
#endif
}

static void restore(void) {
    for (size_t i = 0; i < SIGNAL_COUNT; i++) {
        if (taken[i]) sigaction(signals[i], &previous[i], NULL);
    }
}

static void handler(int signal, siginfo_t *info, void *context) {
    uint64_t self = 0;
    pthread_threadid_np(NULL, &self);
    uint64_t expected = 0;
    if (!atomic_compare_exchange_strong(&handling_thread, &expected, self)) {
        if (expected == self) { // a crash inside the handler: hand it on now
            restore();
            raise(signal);
            return;
        }
        sleep(2); // another thread is writing its report: let it finish, then the app ends
        restore();
        raise(signal);
        return;
    }
    int fd = report_fd;
    if ((int64_t)time(NULL) <= atomic_load(&reported_until)) fd = -1; // already reported: write nothing
    if (fd >= 0) {
        uint64_t pc = 0, lr = 0, fp = 0;
        ucontext_t *uc = (ucontext_t *)context;
        if (uc != NULL && uc->uc_mcontext != NULL) {
#if defined(__arm64__)
            pc = strip((uint64_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
            lr = strip((uint64_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
            fp = (uint64_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
            pc = uc->uc_mcontext->__ss.__rip;
            fp = uc->uc_mcontext->__ss.__rbp;
#endif
        }
        put_string(fd, "lyrelog-crash 1\n");
        put_line(fd, "signal", (uint64_t)signal, 0);
        put_line(fd, "code", info != NULL ? (uint64_t)info->si_code : 0, 0);
        put_line(fd, "address", info != NULL ? (uint64_t)(uintptr_t)info->si_addr : 0, 1);
        put_line(fd, "time", (uint64_t)time(NULL), 0);
        size_t length = note_length;
        if (length > 0) {
            put_string(fd, "note ");
            put(fd, note, length);
            put(fd, "\n", 1);
        }
        put_swift_message(fd);
        int thrown = exception_stack_count;
        for (int i = 0; i < thrown; i++) put_line(fd, "thrown", exception_stack[i], 1);
        if (pc != 0) put_line(fd, "frame", pc, 1);
        // The return addresses saved along the frame pointers. A leaf function may not have
        // saved its caller's address yet: then lr is that caller, unless the chain starts with it.
        uint64_t pair[2];
        int first = 1;
        for (int depth = 0; depth < 128 && fp != 0 && (fp & 7) == 0; depth++) {
            if (!readable(fp, pair)) break;
            // Bit 60 marks a Swift async frame's saved pointer: the address is the rest.
            uint64_t next = pair[0] & ~(1ULL << 60), ret = strip(pair[1]);
            if (first) {
                // Marked apart: the server keeps it only when its symbols show it's another
                // function than the top frame's (a leaf's caller), not a call this one already made.
                if (lr != 0 && lr != ret && lr != pc) put_line(fd, "lr", lr, 1);
                first = 0;
            }
            if (ret == 0) break;
            put_line(fd, "frame", ret, 1);
            if (next <= fp) break; // the stack grows down (async frames live on the heap, above it)
            fp = next;
        }
        if (first && lr != 0 && lr != pc) put_line(fd, "lr", lr, 1);
        put_string(fd, "end\n");
        fsync(fd);
    }
    restore();
    raise(signal);
}

// MARK: - Installing

void lyrelog_crash_note(const char *text) {
    size_t length = text != NULL ? strlen(text) : 0;
    if (length > sizeof(note)) length = sizeof(note);
    note_length = 0;
    for (size_t i = 0; i < length; i++) note[i] = text[i] == '\n' ? ' ' : text[i];
    note_length = length;
}

void lyrelog_crash_note_stack(const unsigned long long *addresses, int count) {
    exception_stack_count = 0;
    if (addresses == NULL || count <= 0) return;
    if (count > (int)(sizeof(exception_stack) / sizeof(exception_stack[0]))) count = (int)(sizeof(exception_stack) / sizeof(exception_stack[0]));
    for (int i = 0; i < count; i++) exception_stack[i] = strip(addresses[i]);
    exception_stack_count = count;
}

void lyrelog_crash_already_reported(int seconds) {
    atomic_store(&reported_until, (int64_t)time(NULL) + seconds);
}

void lyrelog_crash_alternate_stack(void) {
    stack_t stack = {.ss_sp = main_alternate_stack, .ss_size = sizeof(main_alternate_stack), .ss_flags = 0};
    sigaltstack(&stack, NULL);
}

bool lyrelog_crash_install(const char *report_path, const char *images_path) {
    if (report_fd >= 0) return true;
    int images = open(images_path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0600);
    int report = open(report_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (images < 0 || report < 0) {
        if (images >= 0) close(images);
        if (report >= 0) close(report);
        return false;
    }
    images_fd = images;
    report_fd = report;
    // Every image already loaded is reported at once, then each new one.
    _dyld_register_func_for_add_image(image_added);

    stack_t stack = {.ss_sp = alternate_stack, .ss_size = sizeof(alternate_stack), .ss_flags = 0};
    sigaltstack(&stack, NULL); // a stack overflow can still be reported
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < SIGNAL_COUNT; i++) {
        struct sigaction before;
        if (sigaction(signals[i], NULL, &before) != 0) continue;
        // A signal the app ignores stays ignored: taking it and handing it back to SIG_IGN would
        // run the faulting instruction again, forever.
        if (before.sa_handler == SIG_IGN) continue;
        if (sigaction(signals[i], &action, &previous[i]) == 0) taken[i] = 1;
    }
    return true;
}
