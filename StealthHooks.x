// StealthHooks.x - MediaPlaybackUtils v1.4.2 [FIXED]
// Исправления:
//   1. [FIX #3] Убран dispatch_once для _filter_once — фильтр dylib-образов теперь
//      перестраивается при каждом вызове (с лёгким кэшем по версии).
//      Это предотвращает out-of-bounds когда после инициализации загружаются новые dylib:
//      старый фиксированный _filtered_to_real[] переставал соответствовать реальным индексам.
//   2. Кэш версионирован: отслеживаем число образов при последнем построении и перестраиваем
//      только при изменении (O(1) в горячем пути).

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <os/lock.h>

static BOOL _stealth_should_hide_image(const char *name) {
    if (!name) return NO;
    if (strstr(name, "MediaPlaybackUtils")) return YES;
    if (strstr(name, "MobileSubstrate"))    return YES;
    if (strstr(name, "libsubstrate"))        return YES;
    if (strstr(name, "libhooker"))           return YES;
    if (strstr(name, "libellekit"))          return YES;
    if (strstr(name, "Substitute"))          return YES;
    if (strstr(name, "TweakInject"))         return YES;
    if (strstr(name, "ChOma"))               return YES;
    if (strstr(name, "/var/jb/"))            return YES;
    return NO;
}

// ----------------------------------------
// Оригинальные функции
// ----------------------------------------

static uint32_t           (*orig_dyld_image_count)(void);
static const char        *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t           (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

// ----------------------------------------
// Версионированный кэш фильтра
// [FIX #3] Перестраивается когда реальное число образов изменилось
// ----------------------------------------

#define MAX_IMAGES 4096

static os_unfair_lock  _filter_lock      = OS_UNFAIR_LOCK_INIT;
static uint32_t        _filtered_to_real[MAX_IMAGES];
static uint32_t        _filtered_count   = 0;
static uint32_t        _last_real_count  = UINT32_MAX; // заведомо невалидное значение

// Вызывается под локом
static void _stealth_rebuild_filter_locked(void) {
    uint32_t real_count = orig_dyld_image_count();
    _filtered_count = 0;
    for (uint32_t i = 0; i < real_count && _filtered_count < MAX_IMAGES; i++) {
        const char *name = orig_dyld_get_image_name(i);
        if (!_stealth_should_hide_image(name)) {
            _filtered_to_real[_filtered_count++] = i;
        }
    }
    _last_real_count = real_count;
}

// Возвращает текущий отфильтрованный счётчик, при необходимости перестраивает кэш
static uint32_t _stealth_get_filtered_count(void) {
    uint32_t real_count = orig_dyld_image_count();
    os_unfair_lock_lock(&_filter_lock);
    if (real_count != _last_real_count) {
        _stealth_rebuild_filter_locked();
    }
    uint32_t result = _filtered_count;
    os_unfair_lock_unlock(&_filter_lock);
    return result;
}

// Безопасный маппинг filtered_idx → real_idx; возвращает UINT32_MAX при промахе
static uint32_t _stealth_real_idx(uint32_t idx) {
    uint32_t real_count = orig_dyld_image_count();
    os_unfair_lock_lock(&_filter_lock);
    if (real_count != _last_real_count) {
        _stealth_rebuild_filter_locked();
    }
    uint32_t result = (idx < _filtered_count) ? _filtered_to_real[idx] : UINT32_MAX;
    os_unfair_lock_unlock(&_filter_lock);
    return result;
}

// ----------------------------------------
// Хуки dyld
// ----------------------------------------

static uint32_t hook_dyld_image_count(void) {
    return _stealth_get_filtered_count();
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    uint32_t real = _stealth_real_idx(idx);
    if (real == UINT32_MAX) return NULL;
    return orig_dyld_get_image_name(real);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    uint32_t real = _stealth_real_idx(idx);
    if (real == UINT32_MAX) return NULL;
    return orig_dyld_get_image_header(real);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    uint32_t real = _stealth_real_idx(idx);
    if (real == UINT32_MAX) return 0;
    return orig_dyld_get_image_vmaddr_slide(real);
}

// ----------------------------------------
// Хук dladdr
// ----------------------------------------

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

// ----------------------------------------
// Хуки чтения файлов (dpkg/status и /var/jb/)
// ----------------------------------------

%hook NSString

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                                encoding:(NSStringEncoding)enc
                                   error:(NSError **)err {
    if (path) {
        if ([path containsString:@"dpkg/status"] ||
            [path containsString:@"MobileSubstrate"] ||
            [path hasPrefix:@"/var/jb/"]) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                            usedEncoding:(NSStringEncoding *)enc
                                   error:(NSError **)err {
    if (path && ([path containsString:@"dpkg/status"] || [path hasPrefix:@"/var/jb/"])) {
        if (err) *err = nil;
        return @"";
    }
    return %orig;
}

%end

// ----------------------------------------
// Хук NSBundle::allBundles
// ----------------------------------------

%hook NSBundle

+ (NSArray<NSBundle *> *)allBundles {
    NSArray *orig = %orig;
    if (!orig) return orig;

    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bid  = b.bundleIdentifier;
        NSString *path = b.bundlePath;

        if (bid  && [bid  containsString:@"proximacore"])      continue;
        if (bid  && [bid  containsString:@"mediaplaybackutils"]) continue;
        if (path && _stealth_should_hide_image([path fileSystemRepresentation])) continue;

        [clean addObject:b];
    }
    return clean;
}

%end

// ----------------------------------------
// Инициализация
// ----------------------------------------

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        if ([bid hasPrefix:@"com.apple."]) return;

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
        MSHookFunction((void *)dladdr,
                       (void *)hook_dladdr,
                       (void **)&orig_dladdr);

        %init;
        NSLog(@"[MPU/Stealth] Installed for %@", bid);
    }
}
