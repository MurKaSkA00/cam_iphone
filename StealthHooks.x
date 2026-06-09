// StealthHooks.x - MediaPlaybackUtils v1.4.2

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>

// FIX: храним bundleID хоста чтобы не трогать файловые менеджеры
static NSString *_hostBundleID = nil;

// FIX: Filza и Selio не трогаем — только скрываем сам твик
static BOOL _stealth_should_hide_image(const char *name) {
    if (!name) return NO;
    if (strstr(name, "MediaPlaybackUtils")) return YES;
    if (strstr(name, "MobileSubstrate"))    return YES;
    if (strstr(name, "libsubstrate"))       return YES;
    if (strstr(name, "libhooker"))          return YES;
    if (strstr(name, "libellekit"))         return YES;
    if (strstr(name, "Substitute"))         return YES;
    if (strstr(name, "TweakInject"))        return YES;
    if (strstr(name, "ChOma"))              return YES;
    // FIX: убрали блокировку /var/jb/ — там живут Filza, Selio и другие утилиты
    return NO;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

static uint32_t _filtered_to_real[2048];
static uint32_t _filtered_count = 0;
// FIX: убрали dispatch_once — перестраиваем при каждом вызове count
// чтобы не кэшировать устаревший список (Filza вызывает это динамически)
static OSSpinLock _filter_lock = OS_SPINLOCK_INIT;

static void _stealth_rebuild_filter_locked(void) {
    uint32_t real_count = orig_dyld_image_count();
    uint32_t new_count = 0;
    for (uint32_t i = 0; i < real_count && new_count < 2048; i++) {
        const char *name = orig_dyld_get_image_name(i);
        if (!_stealth_should_hide_image(name)) {
            _filtered_to_real[new_count++] = i;
        }
    }
    _filtered_count = new_count;
}

static uint32_t hook_dyld_image_count(void) {
    OSSpinLockLock(&_filter_lock);
    _stealth_rebuild_filter_locked();
    uint32_t c = _filtered_count;
    OSSpinLockUnlock(&_filter_lock);
    return c;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    OSSpinLockLock(&_filter_lock);
    if (idx >= _filtered_count) { OSSpinLockUnlock(&_filter_lock); return NULL; }
    uint32_t real = _filtered_to_real[idx];
    OSSpinLockUnlock(&_filter_lock);
    return orig_dyld_get_image_name(real);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    OSSpinLockLock(&_filter_lock);
    if (idx >= _filtered_count) { OSSpinLockUnlock(&_filter_lock); return NULL; }
    uint32_t real = _filtered_to_real[idx];
    OSSpinLockUnlock(&_filter_lock);
    return orig_dyld_get_image_header(real);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    OSSpinLockLock(&_filter_lock);
    if (idx >= _filtered_count) { OSSpinLockUnlock(&_filter_lock); return 0; }
    uint32_t real = _filtered_to_real[idx];
    OSSpinLockUnlock(&_filter_lock);
    return orig_dyld_get_image_vmaddr_slide(real);
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int hook_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (r != 0 && info && info->dli_fname && _stealth_should_hide_image(info->dli_fname)) {
        info->dli_fname = "/System/Library/Frameworks/Foundation.framework/Foundation";
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
    }
    return r;
}

%hook NSString

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                                encoding:(NSStringEncoding)enc
                                   error:(NSError **)err {
    if (path) {
        // FIX: блокируем только dpkg/status, НЕ трогаем /var/jb/ целиком
        if ([path containsString:@"dpkg/status"] ||
            [path containsString:@"MobileSubstrate"]) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                            usedEncoding:(NSStringEncoding *)enc
                                   error:(NSError **)err {
    if (path && [path containsString:@"dpkg/status"]) {
        if (err) *err = nil;
        return @"";
    }
    return %orig;
}

%end

%hook NSBundle

+ (NSArray<NSBundle *> *)allBundles {
    NSArray *orig = %orig;
    if (!orig) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bid = b.bundleIdentifier;
        if (bid && [bid containsString:@"proximacore"]) continue;
        if (bid && [bid containsString:@"mediaplaybackutils"]) continue;
        // FIX: убрали фильтр по пути — не блокируем бандлы из /var/jb/
        [clean addObject:b];
    }
    return clean;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple."]) return;

        // FIX: сохраняем bundleID хоста для будущих проверок
        _hostBundleID = [bid copy];

        MSHookFunction((void *)_dyld_image_count,
                       (void *)hook_dyld_image_count,
                       (void **)&orig_dyld_image_count);

        MSHookFunction((void *)_dyld_get_image_name,
                       (void *)hook_dyld_get_image_name,
                       (void **)&orig_dyld_get_image_name);

        MSHookFunction((void *)_dyld_get_image_header,
                       (void *)hook_dyld_get_image_header,
                       (void **)&orig_dyld_get_image_header);

        MSHookFunction((void *)_dyld_get_image_vmaddr_slide,
                       (void *)hook_dyld_get_image_vmaddr_slide,
                       (void **)&orig_dyld_get_image_vmaddr_slide);

        MSHookFunction((void *)dladdr, (void *)hook_dladdr, (void **)&orig_dladdr);

        %init;
        NSLog(@"[MPU/Stealth] Installed for %@", bid);
    }
}
