//
//  main.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "ExceptionExfiltrator.h"

#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "platform/native_fault.h"

// The JIT/native backend recovers exact memory-access faults by redirecting
// execution through platform/native_fault.c (shared core -> jit_crash_recover
// -> jit_crash_trampoline). No app scheme ever installed the app-side adapter
// (docs/NATIVE_AOT_IOS.md step 3): the gadget engine takes no recoverable
// host faults in the app, but JIT-translated native code does by design
// (inline TLB miss checkpoints). Install the adapter at load time, before any
// guest code can run. libish.a provides ish_app_native_fault_recover().
static void app_host_fault_handler(int sig, siginfo_t *info, void *ctx) {
    enum ish_fault_result r = ish_app_native_fault_recover(sig, info, ctx);
    if (r == ISH_FAULT_REDIRECTED) {
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return; // recovered: resume at the trampoline's redirected context
    }
    // FATAL (unrecognized native fault: must not replay) or UNHANDLED (not
    // native code: the app's prior policy was no handler, i.e. the default
    // action). Keep dying, but leave one diagnostic line on stderr first.
    char buf[192];
    int len = snprintf(buf, sizeof(buf),
                       "\n=== HOST CRASH: signal %d, addr %p, unrecoverable ===\n",
                       sig, info != NULL ? info->si_addr : NULL);
    (void)write(STDERR_FILENO, buf, (size_t) len);
    _exit(139);
}

__attribute__((constructor))
static void ish_app_install_host_fault_handlers(void) {
    static char altstack[SIGSTKSZ];
    stack_t ss = {.ss_sp = altstack, .ss_size = SIGSTKSZ};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = app_host_fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

int main(int argc, char * argv[]) {
    NSSetUncaughtExceptionHandler(iSHExceptionHandler);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
