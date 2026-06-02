// JailbreakBypass.x - MediaPlaybackUtils v1.4.2
// Скрывает следы джейлбрейка (palera1n rootless, iOS 15-17) от приложения-хоста.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <stdio.h>
#import <string.h>
#import <errno.h>

static NSArray<NSString *> *_jb_blacklist(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"/Applications/Cydia.app", @"/Applications/Sileo.app",
            @"/Applications/Zebra.app", @"/Applications/Installer.app",
            @"/Library/MobileSubstrate", @"/Library/Substitute",
            @"/usr/lib/libsubstrate.dylib", @"/usr/lib/libhooker.dylib",
            @"/usr/lib/substrate", @"/usr/bin/cycript",
            @"/usr/bin/ssh", @"/usr/sbin/sshd",
            @"/etc/apt", @"/etc/ssh/sshd_config",
            @"/private/var/lib/apt", @"/private/var/lib/cydia",
            @"/private/var/stash", @"/private/var/mobile/Library/SBSettings",
            @"/private/var/tmp/cydia.log",
            @"/var/jb", @"/var/jb/Applications/Sileo.app",
            @"/var/jb/Library/MobileSubstrate", @"/var/jb/usr/lib/TweakInject",
            @"/var/jb/usr/lib/libhooker.dylib", @"/var/jb/usr/lib/libsubstrate.dylib",
            @"/var/jb/usr/bin/sileo", @"/var/jb/etc/apt",
            @"/var/jb/var/lib/apt", @"/var/jb/var/lib/dpkg",
            @"/bin/bash", @"/bin/sh",
            @"/var/jb/bin/bash", @"/var/jb/bin/sh",
            @"/.installed_unc0ver", @"/.bootstrapped_electra",
            @"/taurine", @"/jb", @"/palera1n",
        ];
    });
    return list;
}

static BOOL _path_is_blacklisted(const char *path) {
    if (!path) return NO;
    if (strlen(path) == 0) return NO;
    NSString *s = [NSString stringWithUTF8String:path];
    if (!s) return NO;
    for (NSString *bad in _jb_blacklist()) {
        if ([s isEqualToString:bad]) return YES;
        if ([s hasPrefix:[bad stringByAppendingString:@"/"]]) return YES;
    }
    if ([s hasPrefix:@"/var/jb/"]) return YES;
    if ([s hasPrefix:@"/private/var/jb/"]) return YES;
    return NO;
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

static int (*orig_open)(const char *, int, ...);
static int hook_open(const char *path, int flags, ...) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return orig_open(path, flags, mode);
}

static FILE *(*orig_fopen)(const char *, const char *);
static FILE *hook_fopen(const char *path, const char *mode) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

static DIR *(*orig_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    if (_path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_opendir(path);
}

static pid_t (*orig_fork)(void);
static pid_t hook_fork(void) { errno = ENOSYS; return -1; }

static char *(*orig_getenv)(const char *);
static char *hook_getenv(const char *name) {
    if (!name) return orig_getenv(name);
    if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) return NULL;
    if (strcmp(name, "_MSSafeMode") == 0) return NULL;
    if (strcmp(name, "_SafeMode") == 0) return NULL;
    return orig_getenv(name);
}

static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p) {
            if ([p containsString:@"MobileSubstrate"]) return NULL;
            if ([p containsString:@"libsubstrate"]) return NULL;
            if ([p containsString:@"libhooker"]) return NULL;
            if ([p containsString:@"libellekit"]) return NULL;
            if ([p containsString:@"Substitute"]) return NULL;
            if ([p containsString:@"TweakInject"]) return NULL;
            if ([p hasPrefix:@"/var/jb/"]) return NULL;
        }
    }
    return orig_dlopen(path, mode);
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && _path_is_blacklisted([path fileSystemRepresentation])) return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (path && _path_is_blacklisted([path fileSystemRepresentation])) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return %orig;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSArray *orig = %orig;
    if (!orig || !path) return orig;
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/Applications"] || [path isEqualToString:@"/var"]) {
        NSMutableArray *clean = [orig mutableCopy];
        [clean removeObject:@"jb"];
        [clean removeObject:@"Cydia.app"];
        [clean removeObject:@"Sileo.app"];
        [clean removeObject:@"Zebra.app"];
        [clean removeObject:@".installed_unc0ver"];
        [clean removeObject:@".bootstrapped_electra"];
        [clean removeObject:@"palera1n"];
        return clean;
    }
    return orig;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme) {
        if ([scheme isEqualToString:@"cydia"]) return NO;
        if ([scheme isEqualToString:@"sileo"]) return NO;
        if ([scheme isEqualToString:@"zbra"]) return NO;
        if ([scheme isEqualToString:@"filza"]) return NO;
        if ([scheme isEqualToString:@"undecimus"]) return NO;
        if ([scheme isEqualToString:@"activator"]) return NO;
        if ([scheme isEqualToString:@"apt-repo"]) return NO;
    }
    return %orig;
}

- (BOOL)openURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme && ([scheme isEqualToString:@"cydia"] ||
                   [scheme isEqualToString:@"sileo"] ||
                   [scheme isEqualToString:@"zbra"] ||
                   [scheme isEqualToString:@"filza"])) return NO;
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple."]) return;

        MSHookFunction((void *)stat,    (void *)hook_stat,    (void **)&orig_stat);
        MSHookFunction((void *)lstat,   (void *)hook_lstat,   (void **)&orig_lstat);
        MSHookFunction((void *)access,  (void *)hook_access,  (void **)&orig_access);
        MSHookFunction((void *)open,    (void *)hook_open,    (void **)&orig_open);
        MSHookFunction((void *)fopen,   (void *)hook_fopen,   (void **)&orig_fopen);
        MSHookFunction((void *)opendir, (void *)hook_opendir, (void **)&orig_opendir);
        MSHookFunction((void *)fork,    (void *)hook_fork,    (void **)&orig_fork);
        MSHookFunction((void *)getenv,  (void *)hook_getenv,  (void **)&orig_getenv);
        MSHookFunction((void *)dlopen,  (void *)hook_dlopen,  (void **)&orig_dlopen);

        %init;
        NSLog(@"[MPU/JBBypass] Installed for %@", bid);
    }
}
