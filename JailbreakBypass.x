// JailbreakBypass.x - MediaPlaybackUtils v1.4.3 (FIXED)
// Скрывает джейлбрейк ТОЛЬКО от конкретных целевых приложений.
// НЕ убивает Sileo, Filza, palera1n, Chrome.

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

// ========================================
// СПИСОК ПРИЛОЖЕНИЙ, от которых скрываем джейл.
// ИСПРАВЛЕНИЕ: добавь сюда только нужные bundle ID.
// Sileo, Filza, Chrome, palera1n — НЕ должны быть тут.
// ========================================
static NSArray<NSString *> *_jb_targetBundles(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            // Добавь bundle ID приложений, которым нужно скрыть джейл:
            // @"com.example.targetapp",
            // @"com.bank.app",
        ];
    });
    return list;
}

static BOOL _jb_shouldBypass = NO;

static NSArray<NSString *> *_jb_blacklist(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"/Applications/Cydia.app",
            @"/Library/MobileSubstrate",
            @"/Library/Substitute",
            @"/usr/lib/libsubstrate.dylib",
            @"/usr/lib/libhooker.dylib",
            @"/usr/lib/substrate",
            @"/usr/bin/cycript",
            @"/usr/bin/ssh",
            @"/usr/sbin/sshd",
            @"/etc/apt",
            @"/etc/ssh/sshd_config",
            @"/private/var/lib/apt",
            @"/private/var/lib/cydia",
            @"/private/var/stash",
            @"/private/var/tmp/cydia.log",
            // ИСПРАВЛЕНИЕ: /var/jb НЕ добавляем полностью в blacklist,
            // иначе Sileo/Filza которые живут там перестанут работать.
            // Добавляем только конкретные файлы-индикаторы:
            @"/var/jb/.jailbroken",
            @"/.installed_unc0ver",
            @"/.bootstrapped_electra",
            @"/taurine",
            @"/palera1n",
        ];
    });
    return list;
}

static BOOL _path_is_blacklisted(const char *path) {
    if (!path || strlen(path) == 0) return NO;
    NSString *s = [NSString stringWithUTF8String:path];
    if (!s) return NO;
    for (NSString *bad in _jb_blacklist()) {
        if ([s isEqualToString:bad]) return YES;
        if ([s hasPrefix:[bad stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

// ========================================
// SYSCALL HOOKS — активны только если _jb_shouldBypass == YES
// ========================================

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

static int (*orig_open)(const char *, int, ...);
static int hook_open(const char *path, int flags, ...) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return -1; }
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
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

static DIR *(*orig_opendir)(const char *);
static DIR *hook_opendir(const char *path) {
    if (_jb_shouldBypass && _path_is_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_opendir(path);
}

// ИСПРАВЛЕНИЕ: hook_fork УДАЛЁН — он убивал Chrome, WKWebView и другие приложения.
// fork не является надёжным индикатором джейлбрейка в iOS 15+.

static char *(*orig_getenv)(const char *);
static char *hook_getenv(const char *name) {
    if (!name) return orig_getenv(name);
    if (_jb_shouldBypass) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) return NULL;
        if (strcmp(name, "_MSSafeMode") == 0) return NULL;
        if (strcmp(name, "_SafeMode") == 0) return NULL;
    }
    return orig_getenv(name);
}

// ИСПРАВЛЕНИЕ: dlopen hook НЕ блокирует /var/jb/ целиком —
// иначе Sileo и Filza не смогут загрузить свои либы.
static void *(*orig_dlopen)(const char *, int);
static void *hook_dlopen(const char *path, int mode) {
    if (_jb_shouldBypass && path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if (p) {
            // Блокируем только конкретные substrate-библиотеки:
            if ([p hasSuffix:@"/libsubstrate.dylib"]) return NULL;
            if ([p hasSuffix:@"/libhooker.dylib"]) return NULL;
            if ([p hasSuffix:@"/libellekit.dylib"]) return NULL;
            // НЕ блокируем весь /var/jb/ — там живёт Sileo/Filza
        }
    }
    return orig_dlopen(path, mode);
}

// ========================================
// ObjC HOOKS
// ========================================

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation]))
        return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (_jb_shouldBypass && path && _path_is_blacklisted([path fileSystemRepresentation])) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return %orig;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    NSArray *orig = %orig;
    if (!_jb_shouldBypass || !orig || !path) return orig;
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/Applications"]) {
        NSMutableArray *clean = [orig mutableCopy];
        [clean removeObject:@"Cydia.app"];
        [clean removeObject:@"Sileo.app"];     // скрываем от целевого приложения
        [clean removeObject:@".installed_unc0ver"];
        [clean removeObject:@".bootstrapped_electra"];
        return clean;
    }
    return orig;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (!_jb_shouldBypass) return %orig;
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme) {
        if ([scheme isEqualToString:@"cydia"]) return NO;
        if ([scheme isEqualToString:@"sileo"]) return NO;
        if ([scheme isEqualToString:@"zbra"]) return NO;
        // ИСПРАВЛЕНИЕ: filza НЕ убиваем — это нужный инструмент
        if ([scheme isEqualToString:@"undecimus"]) return NO;
        if ([scheme isEqualToString:@"activator"]) return NO;
        if ([scheme isEqualToString:@"apt-repo"]) return NO;
    }
    return %orig;
}

%end

// ========================================
// ИНИЦИАЛИЗАЦИЯ
// ========================================

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        // ИСПРАВЛЕНИЕ: bypass активируем ТОЛЬКО для перечисленных bundle ID.
        // com.apple.* — никогда не трогаем.
        // Sileo, Filza, Chrome — не в списке => bypass НЕ активируется => они работают.

        if ([bid hasPrefix:@"com.apple."]) return;

        NSArray *targets = _jb_targetBundles();
        if (targets.count > 0) {
            // Режим whitelist: только указанные приложения
            _jb_shouldBypass = [targets containsObject:bid];
        } else {
            // Если список пустой — применяем ко всем сторонним приложениям
            // (кроме известных jb-инструментов)
            BOOL isSileo = [bid isEqualToString:@"org.coolstar.SileoStore"];
            BOOL isZebra = [bid isEqualToString:@"xyz.willy.Zebra"];
            BOOL isFilza = [bid isEqualToString:@"com.tigisoftware.Filza"];
            BOOL isChrome = [bid isEqualToString:@"com.google.chrome.ios"];
            BOOL isPalera1n = [bid hasPrefix:@"com.palera1n"];
            _jb_shouldBypass = !(isSileo || isZebra || isFilza || isChrome || isPalera1n);
        }

        if (!_jb_shouldBypass) {
            NSLog(@"[MPU/JBBypass] Skipping bypass for: %@", bid);
            return;
        }

        // Устанавливаем syscall хуки
        MSHookFunction((void *)stat,     (void *)hook_stat,     (void **)&orig_stat);
        MSHookFunction((void *)lstat,    (void *)hook_lstat,    (void **)&orig_lstat);
        MSHookFunction((void *)access,   (void *)hook_access,   (void **)&orig_access);
        MSHookFunction((void *)open,     (void *)hook_open,     (void **)&orig_open);
        MSHookFunction((void *)fopen,    (void *)hook_fopen,    (void **)&orig_fopen);
        MSHookFunction((void *)opendir,  (void *)hook_opendir,  (void **)&orig_opendir);
        // fork НЕ хукаем — убивал Chrome/WKWebView
        MSHookFunction((void *)getenv,   (void *)hook_getenv,   (void **)&orig_getenv);
        MSHookFunction((void *)dlopen,   (void *)hook_dlopen,   (void **)&orig_dlopen);

        %init;
        NSLog(@"[MPU/JBBypass] Active for: %@", bid);
    }
}
