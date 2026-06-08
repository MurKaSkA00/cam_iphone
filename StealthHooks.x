// StealthHooks.x - MediaPlaybackUtils v1.4.3
// Скрывает сам твик от рантайм-интроспекции хоста.
// ПАТЧ: добавлен whitelist — Sileo, Filza и другие jailbreak-приложения
// больше не попадают под фильтрацию /var/jb/ путей.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>

// ─────────────────────────────────────────────
// Бандлы, которым НЕ нужно прятать jailbreak.
// Они сами являются jailbreak-инструментами.
// ─────────────────────────────────────────────
static BOOL _stealth_is_trusted_bundle(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;

    // Sileo, Zebra, Cydia, Installer
    if ([bid isEqualToString:@"org.coolstar.SileoStore"])     return YES;
    if ([bid isEqualToString:@"com.SileoTeam.Sileo"])         return YES;
    if ([bid isEqualToString:@"xyz.willy.Zebra"])              return YES;
    if ([bid isEqualToString:@"com.saurik.Cydia"])             return YES;
    if ([bid isEqualToString:@"com.getwebmaster.installer5"])  return YES;

    // Filza, iFile
    if ([bid isEqualToString:@"com.tigisoftware.Filza"])       return YES;
    if ([bid isEqualToString:@"com.tigisoftware.FilzaEscaped"])return YES;
    if ([bid isEqualToString:@"com.ifile.app"])                return YES;

    // Palera1n, Dopamine UI
    if ([bid hasPrefix:@"com.opa334"])                         return YES;
    if ([bid hasPrefix:@"com.palera1n"])                       return YES;

    // Общий признак: если сам бандл лежит в /var/jb/ — это jailbreak-приложение
    NSString *path = [[NSBundle mainBundle] bundlePath];
    if ([path hasPrefix:@"/var/jb/Applications/"]) return YES;
    if ([path hasPrefix:@"/var/jb/Library/"])      return YES;

    return NO;
}

// ─────────────────────────────────────────────
// Что скрываем от обычных (недоверенных) приложений
// ─────────────────────────────────────────────
static BOOL _stealth_should_hide_image(const char *name) {
    if (!name) return NO;
    if (strstr(name, "MediaPlaybackUtils")) return YES;
    if (strstr(name, "MobileSubstrate"))    return YES;
    if (strstr(name, "libsubstrate"))       return YES;
    if (strstr(name, "libhooker"))          return YES;
    if (strstr(name, "libellekit"))         return YES;
    if (strstr(name, "Substitute"))         return YES;
    if (strstr(name, "TweakInject"))        return YES;
    if (strstr(name, "ChOma"))             return YES;
    // ВАЖНО: /var/jb/ скрываем только если это НЕ доверенный бандл
    // (проверка делается выше, в %ctor — если trusted, хуки вообще не ставятся)
    if (strstr(name, "/var/jb/"))           return YES;
    return NO;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

static uint32_t _filtered_to_real[2048];
static uint32_t _filtered_count = 0;
static dispatch_once_t _filter_once;

static void _stealth_rebuild_filter(void) {
    uint32_t real_count = orig_dyld_image_count();
    _filtered_count = 0;
    for (uint32_t i = 0; i < real_count && _filtered_count < 2048; i++) {
        const char *name = orig_dyld_get_image_name(i);
        if (!_stealth_should_hide_image(name)) {
            _filtered_to_real[_filtered_count++] = i;
        }
    }
}

static uint32_t hook_dyld_image_count(void) {
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    return _filtered_count;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_name(_filtered_to_real[idx]);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_header(_filtered_to_real[idx]);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return 0;
    return orig_dyld_get_image_vmaddr_slide(_filtered_to_real[idx]);
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
        // dpkg/status скрываем всегда (там инфа о твиках)
        if ([path containsString:@"dpkg/status"] ||
            [path containsString:@"MobileSubstrate"]) {
            if (err) *err = nil;
            return @"";
        }
        // /var/jb/ скрываем только от недоверенных приложений
        // (trusted бандлы вообще не получают этот хук — см. %ctor)
        if ([path hasPrefix:@"/var/jb/"]) {
            if (err) *err = nil;
            return @"";
        }
    }
    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                             usedEncoding:(NSStringEncoding *)enc
                                    error:(NSError **)err {
    if (path && ([path containsString:@"dpkg/status"] ||
                 [path hasPrefix:@"/var/jb/"])) {
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
        if (bid && [bid containsString:@"proximacore"])       continue;
        if (bid && [bid containsString:@"mediaplaybackutils"]) continue;
        NSString *path = b.bundlePath;
        if (path && _stealth_should_hide_image([path fileSystemRepresentation])) continue;
        [clean addObject:b];
    }
    return clean;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;

        // Системные процессы Apple — не трогаем
        if ([bid hasPrefix:@"com.apple."]) return;

        // ─── ГЛАВНЫЙ ФИКС ───
        // Если это доверенный jailbreak-инструмент (Sileo, Filza и т.д.) —
        // НЕ устанавливаем стелс-хуки вообще. Пусть видят всё как есть.
        if (_stealth_is_trusted_bundle()) {
            NSLog(@"[MPU/Stealth] Skipping hooks for trusted JB app: %@", bid);
            return;
        }

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
