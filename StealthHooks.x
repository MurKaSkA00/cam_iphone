// StealthHooks.x - MediaPlaybackUtils v1.4.3
// ФИКСЫ v1.4.3:
//   - trusted apps (Sileo, Filza, palera1n) видят полный список dylib
//   - NSString stringWithContentsOfFile: не блокирует dpkg/status

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>

// ─── Trusted check (те же что в JailbreakBypass) ─────────────────────────────
static BOOL _stealth_is_trusted(void) {
    static BOOL trusted = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) return;
        NSArray *whitelist = @[
            @"org.coolstar.SileoStore",
            @"com.silverhawkx.sileo",
            @"xyz.willy.Zebra",
            @"com.tigisoftware.Filza",
            @"com.sparklabs.Installer",
            @"cool.palera1n",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollStorePersistenceHelper",
        ];
        for (NSString *w in whitelist) {
            if ([bid hasPrefix:w] || [bid isEqualToString:w]) {
                trusted = YES;
                return;
            }
        }
        NSString *path = [[NSBundle mainBundle] bundlePath];
        if ([path hasPrefix:@"/var/jb/"]) trusted = YES;
    });
    return trusted;
}

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
    return NO;
    // /var/jb/ убран из фильтра — нельзя скрывать всё подряд
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
    if (_stealth_is_trusted()) return orig_dyld_image_count();
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    return _filtered_count;
}

static const char *hook_dyld_get_image_name(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_name(idx);
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_name(_filtered_to_real[idx]);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_header(idx);
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return NULL;
    return orig_dyld_get_image_header(_filtered_to_real[idx]);
}

static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    if (_stealth_is_trusted()) return orig_dyld_get_image_vmaddr_slide(idx);
    dispatch_once(&_filter_once, ^{ _stealth_rebuild_filter(); });
    if (idx >= _filtered_count) return 0;
    return orig_dyld_get_image_vmaddr_slide(_filtered_to_real[idx]);
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int hook_dladdr(const void *addr, Dl_info *info) {
    int r = orig_dladdr(addr, info);
    if (_stealth_is_trusted()) return r;
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
    if (!_stealth_is_trusted() && path) {
        // dpkg/status НЕ трогаем — нужен Sileo
        if (![path containsString:@"dpkg/status"] &&
            ![path containsString:@"dpkg/info"]) {
            if ([path containsString:@"MobileSubstrate"] ||
                [path hasPrefix:@"/var/jb/usr/lib/TweakInject"]) {
                if (err) *err = nil;
                return @"";
            }
        }
    }
    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path
                            usedEncoding:(NSStringEncoding *)enc
                                   error:(NSError **)err {
    if (!_stealth_is_trusted() && path) {
        if (![path containsString:@"dpkg/status"] &&
            ![path containsString:@"dpkg/info"]) {
            if ([path containsString:@"MobileSubstrate"] ||
                [path hasPrefix:@"/var/jb/usr/lib/TweakInject"]) {
                if (err) *err = nil;
                return @"";
            }
        }
    }
    return %orig;
}

%end

%hook NSBundle

+ (NSArray<NSBundle *> *)allBundles {
    NSArray *orig = %orig;
    if (!orig || _stealth_is_trusted()) return orig;
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSBundle *b in orig) {
        NSString *bid  = b.bundleIdentifier;
        NSString *bpath = b.bundlePath;
        if (bid && ([bid containsString:@"proximacore"] ||
                    [bid containsString:@"mediaplaybackutils"])) continue;
        if (bpath && _stealth_should_hide_image([bpath fileSystemRepresentation])) continue;
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
