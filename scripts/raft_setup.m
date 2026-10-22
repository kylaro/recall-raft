/* Native setup worker for Recall Raft. Original project contributions: Apache-2.0.
 *
 * Adapted from Recall's worker (scripts/portable_setup.m in AsherJN/recall): the same owned
 * data folder, verified runtime install, Wine environment and session checks, with Steam in
 * place of Battle.net and Raft in place of Overwatch. Foundation, libarchive and CommonCrypto
 * come with macOS; there is no player-side Python. The app supplies a reviewed archive and
 * installer hash, never downloaded instructions. JSON events on stdout are account-free.
 *
 *   raft-setup <command> [--root DIR] [--option value ...]
 *
 * Commands: preflight, status, install-runtime, verify, prepare, install-steam, launch,
 * watch, session, close-steam, stop, uninstall.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <archive.h>
#include <archive_entry.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

// Raft on Steam (store.steampowered.com/app/648800).
#define RAFT_APP_ID @"648800"
#define OWNER_MARKER @".recall-raft-owner"
#define OWNER_TEXT "recall-raft-setup-v1\n"
#define RUNTIME_VERSION_PATTERN @"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

static NSFileManager *fm;
static NSString *root;
static int lockFD = -1;
static BOOL monitorMode;
static BOOL ownedPreparation;
static volatile sig_atomic_t childPID;
static volatile sig_atomic_t cancelRequested;
static void cancelled(int sig) { cancelRequested=sig; if (childPID > 0) kill(childPID, SIGTERM); }
static void fail(NSString *code) { @throw [NSException exceptionWithName:@"SetupError" reason:code userInfo:nil]; }
static NSString *join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static void event(NSString *stage, NSDictionary *details) {
    NSMutableDictionary *value = [@{@"stage":stage} mutableCopy];
    [value addEntriesFromDictionary:details ?: @{}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static void mkdirs(NSString *path) {
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions:@0700} error:nil]) fail(@"directory_creation_failed");
}
static void writeJSON(id object, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) fail(@"state_write_failed");
}
static NSDictionary *readJSON(NSString *path) {
    if ([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue] > (8ULL<<20)) fail(@"manifest_size_limit");
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) fail(@"invalid_manifest");
    return value;
}
static BOOL matches(NSString *s, NSString *pattern) {
    if (![s isKindOfClass:NSString.class]) return NO;
    NSRange range = [s rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == s.length;
}
static BOOL safePath(NSString *s) {
    if (!s.length || [s hasPrefix:@"/"] || [s containsString:@"\\"] || [s containsString:@"\n"] ||
        [s containsString:@"\r"] || [s containsString:@"\t"]) return NO;
    for (NSString *part in [s componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static NSString *hashFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) fail(@"file_read_failed");
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) { close(fd); fail(@"file_not_regular"); }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    unsigned char buffer[1024*128], digest[CC_SHA256_DIGEST_LENGTH]; ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    close(fd); if (count < 0) fail(@"file_read_failed");
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString string];
    for (unsigned int i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static uint64_t freeBytes(void) {
    return [[fm attributesOfFileSystemForPath:root error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static void space(uint64_t needed) { if (freeBytes() < needed) fail(@"insufficient_disk_space"); }

#pragma mark - The owned data folder

static void supportedVolume(NSString *path) {
    // Wine needs POSIX symlinks and Windows games expect case-insensitive
    // names: only APFS or Mac OS Extended, never case-sensitive or read-only.
    struct statfs fs;
    if (statfs(path.fileSystemRepresentation, &fs)) fail(@"install_location_unavailable");
    if (strcmp(fs.f_fstypename, "apfs") && strcmp(fs.f_fstypename, "hfs")) fail(@"unsupported_volume_format");
    if (fs.f_flags & MNT_RDONLY) fail(@"read_only_volume");
    if (pathconf(path.fileSystemRepresentation, _PC_CASE_SENSITIVE) == 1) fail(@"case_sensitive_volume");
}
static void ownRoot(NSString *requested) {
    root = [[requested stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (![root isAbsolutePath] || [root isEqual:@"/"] || [root isEqual:NSHomeDirectory()]) fail(@"unsafe_install_directory");
    // Only the data folder itself is ever created: a disconnected drive must not
    // turn into a stray folder on the internal disk.
    NSString *parent = [root stringByDeletingLastPathComponent];
    BOOL parentIsDirectory = NO;
    if (![fm fileExistsAtPath:root] && !([fm fileExistsAtPath:parent isDirectory:&parentIsDirectory] && parentIsDirectory))
        fail(@"install_location_unavailable");
    NSString *marker = join(root, OWNER_MARKER);
    if ([fm fileExistsAtPath:root] && ![fm fileExistsAtPath:marker] &&
        [fm contentsOfDirectoryAtPath:root error:nil].count) fail(@"directory_not_owned_by_app");
    if (![fm fileExistsAtPath:marker]) supportedVolume([fm fileExistsAtPath:root] ? root : parent);
    mkdirs(root);
    struct stat st;
    if (lstat(root.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) fail(@"directory_not_owned_by_user");
    if (chmod(root.fileSystemRepresentation, 0700)) fail(@"private_directory_permissions_failed");
    int markerFD = open(marker.fileSystemRepresentation, O_RDWR|O_CREAT|O_NOFOLLOW, 0600);
    if (markerFD < 0) fail(@"invalid_ownership_marker");
    char bytes[32] = {0}; ssize_t n = read(markerFD, bytes, sizeof(bytes)); size_t length = strlen(OWNER_TEXT);
    if (n == 0) { if (write(markerFD, OWNER_TEXT, length) != (ssize_t)length) { close(markerFD); fail(@"ownership_write_failed"); } }
    else if (n != (ssize_t)length || memcmp(bytes, OWNER_TEXT, length)) { close(markerFD); fail(@"invalid_ownership_marker"); }
    close(markerFD);
    lockFD = open(join(root, @"setup.lock").fileSystemRepresentation, O_CREAT|O_RDWR|O_NOFOLLOW, 0600);
    if (lockFD < 0) fail(@"setup_already_running");
    if (!monitorMode && flock(lockFD, LOCK_EX|LOCK_NB)) fail(@"setup_already_running");
    for (NSString *directory in @[@"runtimes", @"downloads", @"logs", @"home", @"tmp", @"cache"])
        mkdirs(join(root, directory));
}
static NSMutableDictionary *state(void) {
    NSString *p = join(root, @"state.json");
    return [fm fileExistsAtPath:p] ? [readJSON(p) mutableCopy] : [@{@"schema":@1, @"stage":@"not_installed"} mutableCopy];
}
static void saveState(NSString *key, id value) {
    NSMutableDictionary *s = state(); s[key] = value; writeJSON(s, join(root, @"state.json"));
}
static void saveStage(NSString *stage) { saveState(@"stage", stage); event(stage, nil); }
static NSString *runtime(void) {
    NSString *version = state()[@"active_runtime"];
    if (!matches(version, RUNTIME_VERSION_PATTERN)) fail(@"runtime_not_installed");
    NSString *p = join(join(root, @"runtimes"), version);
    if (![fm fileExistsAtPath:join(p, @"runtime.json")]) fail(@"runtime_missing");
    return p;
}

#pragma mark - Wine processes

static NSString *steamFolder(void) { return join(root, @"environment/drive_c/Program Files (x86)/Steam"); }
static NSString *steamPath(void) { return join(steamFolder(), @"Steam.exe"); }
static NSString *webhelperFolder(void) { return join(steamFolder(), @"bin/cef/cef.win64"); }
static NSString *raftPath(void) { return join(steamFolder(), @"steamapps/common/Raft/Raft.exe"); }

/* Recall's tuned DXMT/Wine environment (its launch contract), for Raft: the graphics go
 * through DXMT on Metal with three drawables, shaders are prepared as the game creates them
 * and the pipeline cache gets its own namespace. WINEMAC_MOUSELOOK gives Raft, a first-person
 * game, Recall's raw mouse input while it hides and confines the cursor. Steam's programs
 * get Windows' 200% DPI (Recall's WINE_APP_DPI), so with Wine's Retina mode they have their
 * Windows size in points; Raft keeps 96 and draws at the display's full pixel count. */
static NSMutableDictionary *wineEnv(NSString *engine) {
    // Keep Wine's Windows profile and shell folders inside the owned folder. Never borrow
    // the player's HOME, account state or caches.
    return [@{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin", @"HOME":join(root, @"home"), @"USER":@"player",
        @"TMPDIR":join(root, @"tmp"), @"WINEPREFIX":join(root, @"environment"), @"WINEARCH":@"win64",
        @"WINESERVER":join(engine, @"bin/wineserver"), @"WINELOADER":join(engine, @"bin/wine"), @"WINEDEBUG":@"-all",
        @"WINEDLLOVERRIDES":@"d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=",
        @"WINEESYNC":@"0", @"WINEMSYNC":@"1", @"WINE_SIMULATE_WRITECOPY":@"1", @"ROSETTA_ADVERTISE_AVX":@"1",
        @"WINEMAC_MOUSELOOK":@"Raft.exe", @"WINE_APP_DPI":@"192:Steam.exe;steamwebhelper.exe;SteamSetup.exe",
        @"CX_GRAPHICS_BACKEND":@"dxmt", @"CX_ACTIVE_GRAPHICS_BACKEND":@"dxmt",
        @"CX_APPLEGPTK_LIBD3DSHARED_PATH":join(engine, @"lib/external/libd3dshared.dylib"),
        @"DXMT_CONFIG_FILE":[@"Z:" stringByAppendingString:[join(engine, @"config/dxmt.conf") stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]],
        @"DXMT_LOG_LEVEL":@"error", @"DXMT_LOG_PATH":@"none", @"DXMT_CANVAS_DRAWABLES":@"3", @"DXMT_CANVAS_OVERLAY":@"0",
        @"DXMT_PREPARE_SHADERS":@"1", @"DXMT_USE_DEFAULT_METAL_CACHE":@"1",
        @"DXMT_SHADER_CACHE_PATH":join(root, @"cache/shaders"), @"DXMT_PIPELINE_CACHE_PATH":join(root, @"cache/pipelines"),
        @"DXMT_PIPELINE_CACHE_NAMESPACE":@"raft-v1", @"DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE":@"1",
        @"DXMT_PIPELINE_CACHE_PREWARM_LIMIT":@"128", @"DXMT_PIPELINE_CACHE_PREWARM_MS":@"10000"} mutableCopy];
}
static NSTask *task(NSString *executable, NSArray *args, NSDictionary *env, NSString *logname) {
    NSTask *p = [NSTask new]; p.executableURL = [NSURL fileURLWithPath:executable]; p.arguments = args;
    if (env) p.environment = env;
    p.currentDirectoryURL = [NSURL fileURLWithPath:root];
    NSString *log = join(join(root, @"logs"), logname);
    if (![fm fileExistsAtPath:log]) [fm createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:log]; [out truncateFileAtOffset:0];
    p.standardOutput = out; p.standardError = out;
    if (![p launchAndReturnError:nil]) fail(@"process_launch_failed");
    return p;
}
static int waitTask(NSTask *p, double seconds) {
    childPID = p.processIdentifier;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (p.running && deadline.timeIntervalSinceNow > 0 && !cancelRequested) [NSThread sleepForTimeInterval:0.05];
    if (p.running) {
        kill(p.processIdentifier, SIGTERM);
        NSDate *grace = [NSDate dateWithTimeIntervalSinceNow:2];
        while (p.running && grace.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
        if (p.running) kill(p.processIdentifier, SIGKILL);
        [p waitUntilExit]; childPID = 0; if (cancelRequested) fail(@"cancelled"); return 124;
    }
    [p waitUntilExit]; childPID = 0; if (cancelRequested) fail(@"cancelled"); return p.terminationStatus;
}
static int wine(NSString *engine, NSArray *args, NSString *log, double seconds) {
    return waitTask(task(join(engine, @"bin/wine"), args, wineEnv(engine), log), seconds);
}
static BOOL serverIdle(NSString *engine, double seconds) {
    return waitTask(task(join(engine, @"bin/wineserver"), @[@"-w"], wineEnv(engine), @"server-wait.log"), seconds) == 0;
}
static void endSession(NSString *engine) {
    waitTask(task(join(engine, @"bin/wineserver"), @[@"-k"], wineEnv(engine), @"session-end.log"), 15);
    if (!serverIdle(engine, 15)) fail(@"steam_close_failed");
}

/* Exact engine/prefix process membership, as in Recall: a process counts only when it has
 * this runtime's loader and this environment mapped. No command lines or environments. */
static NSString *capture(NSString *exe, NSArray *args) {
    NSString *name = [NSString stringWithFormat:@"session-query-%d.log", getpid()];
    if (waitTask(task(exe, args, @{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin", @"LC_ALL":@"C"}, name), 5)) return nil;
    NSString *path = join(join(root, @"logs"), name);
    if ([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue] > (4ULL<<20)) return nil;
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}
static NSMutableDictionary *membershipCache;
static NSArray *sessionProcesses(void) {
    if (!membershipCache || membershipCache.count > 256) membershipCache = [NSMutableDictionary dictionary];
    NSString *engine = [runtime() stringByAppendingString:@"/"], *prefix = [join(root, @"environment") stringByAppendingString:@"/"];
    NSString *table = capture(@"/bin/ps", @[@"-axo", @"pid=,lstart=,comm="]);
    if (!table) fail(@"session_check_failed");
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(\\d+)\\s+(\\S+\\s+\\S+\\s+\\d+\\s+\\S+\\s+\\d+)\\s+(.+)$" options:0 error:nil];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *line in [table componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m = [rx firstMatchInString:line options:0 range:NSMakeRange(0, line.length)]; if (!m) continue;
        // Wine names a process by the path it started from: C:\... from Windows, /... when
        // the worker starts Steam from macOS.
        NSString *name = [[[line substringWithRange:[m rangeAtIndex:3]] lowercaseString] stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
        NSString *kind = [name hasSuffix:@"\\raft.exe"] ? @"game" : [name hasSuffix:@"\\steam.exe"] ? @"steam" :
                         [name hasSuffix:@"\\steamwebhelper.exe"] ? @"webhelper" : nil;
        if (!kind) continue;
        NSString *pid = [line substringWithRange:[m rangeAtIndex:1]], *start = [line substringWithRange:[m rangeAtIndex:2]];
        NSString *identity = [NSString stringWithFormat:@"%@|%@", pid, start];
        NSDictionary *row = @{@"pid":@(pid.intValue), @"identity":start, @"kind":kind};
        if (membershipCache[identity]) { if ([membershipCache[identity] boolValue]) [found addObject:row]; continue; }
        NSString *mapped = capture(@"/usr/sbin/lsof", @[@"-a", @"-p", pid, @"-d", @"txt", @"-Fn"]);
        if (!mapped) { if (kill(pid.intValue, 0) == 0) fail(@"session_membership_unknown"); continue; }
        BOOL hasEngine = NO, hasPrefix = NO;
        for (NSString *file in [mapped componentsSeparatedByString:@"\n"]) {
            if (![file hasPrefix:@"n"]) continue;
            // lsof escapes literal backslashes even in field output.
            NSString *path = [[[file substringFromIndex:1] stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"] stringByResolvingSymlinksInPath];
            hasEngine |= [path hasPrefix:engine];
            hasPrefix |= [path hasPrefix:prefix];
        }
        membershipCache[identity] = @(hasEngine && hasPrefix);
        if (hasEngine && hasPrefix) [found addObject:row];
    }
    // Raw process inventory never becomes a retained support record.
    [fm removeItemAtPath:join(join(root, @"logs"), [NSString stringWithFormat:@"session-query-%d.log", getpid()]) error:nil];
    return found;
}
static BOOL running(NSArray *processes, NSString *kind) {
    for (NSDictionary *p in processes) if ([p[@"kind"] isEqual:kind]) return YES;
    return NO;
}
static BOOL busy(NSString *engine) {
    if (![fm fileExistsAtPath:join(root, @"environment")]) return NO;
    // A newly signed x86_64 server may need first-launch Rosetta translation, so a
    // subsecond deadline would misread its startup as a running session.
    int result = waitTask(task(join(engine, @"bin/wineserver"), @[@"-w"], wineEnv(engine), @"server-check.log"), 5);
    if (result != 0 && result != 124) fail(@"server_check_failed");
    return result == 124;
}

#pragma mark - Checks, downloads and the runtime

// Tests build the worker with a probe that fails, as on a Mac without Rosetta.
#ifndef ROSETTA_PROBE
#define ROSETTA_PROBE @"/usr/bin/arch"
#endif
// Steam, Raft and Wine are Intel programs. A macOS upgrade can remove Rosetta,
// so launches check too, before anything starts Wine.
static void requireRosetta(void) {
    if (waitTask(task(ROSETTA_PROBE, @[@"-x86_64", @"/usr/bin/true"], nil, @"rosetta-check.log"), 10)) fail(@"rosetta_required");
}
static void preflight(void) {
    int silicon = 0; size_t size = sizeof(silicon);
    sysctlbyname("hw.optional.arm64", &silicon, &size, NULL, 0);
    if (!silicon) fail(@"apple_silicon_required");
    requireRosetta();
    event(@"preflight_ok", @{@"free_bytes":@(freeBytes())});
}
static NSString *download(NSString *url, NSString *expected) {
    if (!matches(expected, @"^[a-f0-9]{64}$")) fail(@"invalid_download_hash");
    NSURL *u = [NSURL URLWithString:url];
    if (![u.scheme isEqual:@"https"] || !u.host.length || u.user || u.password) fail(@"https_download_required");
    NSString *dest = join(join(root, @"downloads"), expected);
    if ([fm fileExistsAtPath:dest]) {
        if (![hashFile(dest) isEqual:expected]) fail(@"cached_download_hash_mismatch");
        return dest;
    }
    space(1ULL<<30);
    NSString *part = [dest stringByAppendingString:@".part"];
    event(@"downloading", nil);
    NSArray *args = @[@"--fail", @"--location", @"--proto", @"=https", @"--proto-redir", @"=https", @"--retry", @"2",
        @"--connect-timeout", @"20", @"--max-time", @"900", @"--max-filesize", @"536870912", @"--output", part, url];
    if (waitTask(task(@"/usr/bin/curl", args, nil, @"download.log"), 910)) { [fm removeItemAtPath:part error:nil]; fail(@"download_failed"); }
    if (![hashFile(part) isEqual:expected]) { [fm removeItemAtPath:part error:nil]; fail(@"download_hash_mismatch"); }
    if (![fm moveItemAtPath:part toPath:dest error:nil]) fail(@"download_commit_failed");
    event(@"download_verified", nil);
    return dest;
}
static void extract(NSString *archivePath, NSString *destination) {
    struct archive *a = archive_read_new(); archive_read_support_filter_gzip(a); archive_read_support_format_tar(a);
    if (archive_read_open_filename(a, archivePath.fileSystemRepresentation, 131072) != ARCHIVE_OK) fail(@"archive_open_failed");
    NSMutableSet *seen = [NSMutableSet set]; NSMutableArray *links = [NSMutableArray array];
    struct archive_entry *entry; uint64_t total = 0; int result;
    @try {
        while ((result = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
            if (cancelRequested) fail(@"cancelled");
            NSString *name = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
            if ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
            if (!safePath(name) || [seen containsObject:name.lowercaseString] || seen.count > 20000) fail(@"unsafe_archive_path");
            [seen addObject:name.lowercaseString];
            if (archive_entry_hardlink(entry)) fail(@"archive_hardlink_rejected");
            mode_t type = archive_entry_filetype(entry); NSString *dest = join(destination, name);
            if (type == AE_IFLNK) {
                const char *raw = archive_entry_symlink(entry); NSString *link = raw ? [NSString stringWithUTF8String:raw] : nil;
                if (!link.length || [link hasPrefix:@"/"] || [link containsString:@"\\"]) fail(@"unsafe_archive_symlink");
                NSString *resolved = [[name.stringByDeletingLastPathComponent stringByAppendingPathComponent:link] stringByStandardizingPath];
                if (!safePath(resolved)) fail(@"archive_symlink_escapes_runtime");
                [links addObject:@[dest, link]]; continue;
            }
            if (type != AE_IFREG && type != AE_IFDIR) fail(@"archive_special_file_rejected");
            mkdirs(dest.stringByDeletingLastPathComponent);
            if (type == AE_IFDIR) { mkdirs(dest); continue; }
            la_int64_t length = archive_entry_size(entry);
            if (length < 0 || length > (2LL<<30) || total + (uint64_t)length > (8ULL<<30)) fail(@"archive_size_limit");
            total += (uint64_t)length;
            int fd = open(dest.fileSystemRepresentation, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, archive_entry_perm(entry) & 0111 ? 0755 : 0644);
            if (fd < 0) fail(@"archive_file_creation_failed");
            char buffer[131072]; la_ssize_t n; uint64_t wrote = 0;
            while ((n = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
                ssize_t offset = 0;
                while (offset < n) { ssize_t count = write(fd, buffer + offset, (size_t)(n - offset)); if (count <= 0) { close(fd); fail(@"archive_write_failed"); } offset += count; }
                wrote += (uint64_t)n;
            }
            close(fd); if (n < 0 || wrote != (uint64_t)length) fail(@"archive_truncated");
        }
        if (result != ARCHIVE_EOF) fail(@"archive_corrupt");
        // No symlink can be traversed during extraction: create all of them last.
        for (NSArray *link in links) {
            mkdirs([link[0] stringByDeletingLastPathComponent]);
            if (symlink([link[1] fileSystemRepresentation], [link[0] fileSystemRepresentation])) fail(@"archive_symlink_failed");
        }
        for (NSArray *link in links)
            if (![[link[0] stringByResolvingSymlinksInPath] hasPrefix:[destination stringByAppendingString:@"/"]]) fail(@"archive_symlink_escapes_runtime");
    } @finally { archive_read_free(a); }
}
static void verifyRuntime(NSString *engine, NSString *version) {
    NSDictionary *manifest = readJSON(join(engine, @"runtime.json"));
    if (![manifest[@"version"] isEqual:version] || ![manifest[@"files"] isKindOfClass:NSDictionary.class]) fail(@"runtime_identity_mismatch");
    NSDictionary *files = manifest[@"files"];
    for (NSString *name in files) {
        if (cancelRequested) fail(@"cancelled");
        if (!safePath(name)) fail(@"unsafe_manifest_path");
        NSDictionary *spec = files[name]; NSString *p = join(engine, name); struct stat st;
        if (lstat(p.fileSystemRepresentation, &st)) fail(@"runtime_file_missing");
        if (spec[@"symlink"]) {
            if (!S_ISLNK(st.st_mode) || ![[fm destinationOfSymbolicLinkAtPath:p error:nil] isEqual:spec[@"symlink"]]) fail(@"runtime_link_mismatch");
        } else if (!S_ISREG(st.st_mode) || ![hashFile(p) isEqual:spec[@"sha256"]]) fail(@"runtime_file_hash_mismatch");
    }
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:engine]; NSString *name;
    while ((name = [enumerator nextObject])) {
        struct stat st; if (lstat(join(engine, name).fileSystemRepresentation, &st)) fail(@"runtime_file_missing");
        // Finder writes .DS_Store into any folder a player opens; nothing loads it.
        if (S_ISREG(st.st_mode) && [name.lastPathComponent isEqual:@".DS_Store"]) continue;
        if (!S_ISDIR(st.st_mode) && ![name isEqual:@"runtime.json"] && !files[name]) fail(@"runtime_unlisted_file");
    }
    for (NSString *required in @[@"bin/wine", @"bin/wineserver", @"config/dxmt.conf", @"lib/external/libd3dshared.dylib",
                                 @"lib/wine/x86_64-unix/winemetal.so", @"lib/wine/x86_64-unix/winemac.so",
                                 @"lib/wine/x86_64-windows/d3d11.dll", @"lib/wine/x86_64-windows/dxgi.dll"])
        if (!files[required]) fail(@"runtime_required_component_missing");
    for (NSString *architecture in @[@"x86_64-windows", @"i386-windows"])
        for (NSString *module in @[@"winemac.drv", @"kernel32.dll", @"ntdll.dll", @"wscript.exe"])
            if (!files[join(join(@"lib/wine", architecture), module)]) fail(@"runtime_required_component_missing");
}
// Keep the active runtime and the one before it; older ones this worker installed go.
static void pruneRuntimes(NSString *active, NSString *previous) {
    NSString *directory = join(root, @"runtimes");
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name isEqual:active] || [name isEqual:previous] || !matches(name, RUNTIME_VERSION_PATTERN)) continue;
        NSString *path = join(directory, name); struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || ![fm fileExistsAtPath:join(path, @"runtime.json")]) continue;
        [fm removeItemAtPath:path error:nil];
    }
}
static void installRuntime(NSString *archivePath, NSString *expected, NSString *version, BOOL repair) {
    if (!matches(version, RUNTIME_VERSION_PATTERN) || !matches(expected, @"^[a-f0-9]{64}$")) fail(@"invalid_runtime_identity");
    if (state()[@"active_runtime"] && busy(runtime())) fail(@"close_steam_before_maintenance");
    if (![hashFile(archivePath) isEqual:expected]) fail(@"archive_hash_mismatch");
    space(3ULL<<30);
    NSString *target = join(join(root, @"runtimes"), version), *stage = join(root, @"incoming-runtime");
    saveStage(@"installing_runtime");
    if ([fm fileExistsAtPath:target] && !repair) verifyRuntime(target, version);
    else {
        // Repair extracts a fresh copy and swaps it in; the old copy goes only after the new one verified.
        if ([fm fileExistsAtPath:stage] && ![fm removeItemAtPath:stage error:nil]) fail(@"staging_cleanup_failed");
        mkdirs(stage); extract(archivePath, stage); verifyRuntime(stage, version);
        NSString *replaced = join(root, @"replaced-runtime");
        if ([fm fileExistsAtPath:replaced] && ![fm removeItemAtPath:replaced error:nil]) fail(@"staging_cleanup_failed");
        if ([fm fileExistsAtPath:target] && ![fm moveItemAtPath:target toPath:replaced error:nil]) fail(@"runtime_commit_failed");
        if (![fm moveItemAtPath:stage toPath:target error:nil]) fail(@"runtime_commit_failed");
        [fm removeItemAtPath:replaced error:nil];
    }
    NSMutableDictionary *s = state(); NSString *previous = s[@"active_runtime"];
    if (previous && ![previous isEqual:version]) { s[@"previous_runtime"] = previous; [s removeObjectForKey:@"prepared_runtime"]; }
    if (repair) [s removeObjectForKey:@"prepared_runtime"];
    s[@"active_runtime"] = version; s[@"stage"] = @"runtime_ready"; writeJSON(s, join(root, @"state.json"));
    pruneRuntimes(version, s[@"previous_runtime"]);
    event(@"runtime_ready", @{@"version":version});
}

#pragma mark - The Windows environment

static BOOL registryValue(NSString *file, NSString *section, NSString *line) {
    NSString *text = [NSString stringWithContentsOfFile:join(join(root, @"environment"), file) encoding:NSUTF8StringEncoding error:nil];
    BOOL inside = NO;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([l hasPrefix:@"["]) inside = [l.lowercaseString hasPrefix:[NSString stringWithFormat:@"[%@]", section].lowercaseString];
        else if (inside && [l isEqual:line]) return YES;
    }
    return NO;
}
/* The settings the environment needs, applied with Wine's registry tool while nothing runs:
 * - Retina mode, so Raft and Steam draw at the display's full pixel count;
 * - the native version.dll beside Steam's web helper first (installWebhelperFix). */
static void configureEnvironment(NSString *engine) {
    NSArray *settings = @[
        @[@"user.reg", @"Software\\\\Wine\\\\Mac Driver", @"\"RetinaMode\"=\"Y\"",
          @[@"reg.exe", @"add", @"HKCU\\Software\\Wine\\Mac Driver", @"/v", @"RetinaMode", @"/t", @"REG_SZ", @"/d", @"Y", @"/f"]],
        @[@"user.reg", @"Software\\\\Wine\\\\AppDefaults\\\\steamwebhelper.exe\\\\DllOverrides", @"\"version\"=\"native,builtin\"",
          @[@"reg.exe", @"add", @"HKCU\\Software\\Wine\\AppDefaults\\steamwebhelper.exe\\DllOverrides", @"/v", @"version", @"/t", @"REG_SZ", @"/d", @"native,builtin", @"/f"]]];
    BOOL changed = NO;
    for (NSArray *setting in settings) {
        if (registryValue(setting[0], setting[1], setting[2])) continue;
        if (wine(engine, setting[3], @"registry.log", 60)) fail(@"environment_configuration_failed");
        changed = YES;
    }
    // The registry tool starts Wine itself; let its server exit and save before Steam starts.
    if (changed && !serverIdle(engine, 60)) fail(@"environment_initialization_busy");
    for (NSArray *setting in settings) if (!registryValue(setting[0], setting[1], setting[2])) fail(@"environment_configuration_failed");
}
static void prepare(void) {
    preflight(); NSString *engine = runtime(); verifyRuntime(engine, state()[@"active_runtime"]);
    if (busy(engine)) fail(@"close_steam_before_setup");
    space(2ULL<<30);
    NSString *prefix = join(root, @"environment"), *marker = join(root, @"environment-owned.json");
    if ([fm fileExistsAtPath:prefix] && ![fm fileExistsAtPath:marker]) fail(@"existing_environment_not_owned");
    if (![fm fileExistsAtPath:marker]) writeJSON(@{@"schema":@1, @"runtime":state()[@"active_runtime"]}, marker);
    saveStage(@"preparing_environment"); ownedPreparation = YES;
    if (wine(engine, @[@"wineboot.exe", @"-u", @"-r"], @"wineboot.log", 180)) fail(@"environment_initialization_failed");
    if (!serverIdle(engine, 60)) fail(@"environment_initialization_busy");
    if (![fm fileExistsAtPath:join(prefix, @"system.reg")]) fail(@"environment_registry_missing");
    configureEnvironment(engine);
    saveState(@"prepared_runtime", state()[@"active_runtime"]);
    saveStage(@"environment_ready"); ownedPreparation = NO;
}

#pragma mark - Steam

/* The worker's version.dll for Steam's web helper (windows/webhelper-gpu/version.c): it keeps
 * Chromium's GPU work in Steam's browser process, without which Steam's windows are black.
 * It lives in the app beside this worker, or wherever --webhelper-dll says. */
static NSString *bundledWebhelperFix(NSString *option) {
    if (option) return option;
    NSString *helpers = [NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent];
    return join([helpers stringByDeletingLastPathComponent], @"Resources/webhelper/version.dll");
}
// A version.dll this project made says so: its command-line switch is in it as UTF-16.
static BOOL ourWebhelperFix(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSData *marker = [@"--in-process-gpu" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    return data.length < (1<<20) && marker && [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}
/* Copies the fix beside steamwebhelper.exe; NO while Steam hasn't downloaded its web helper
 * yet (a new installation's first start). Never replaces a version.dll Steam itself put there. */
static BOOL installWebhelperFix(NSString *fix) {
    NSString *folder = webhelperFolder(), *dest = join(folder, @"version.dll");
    if (![fm fileExistsAtPath:join(folder, @"steamwebhelper.exe")]) return NO;
    if (![fm isReadableFileAtPath:fix] || !ourWebhelperFix(fix)) fail(@"webhelper_fix_missing");
    NSString *expected = hashFile(fix);
    if ([fm fileExistsAtPath:dest]) {
        if ([hashFile(dest) isEqual:expected]) return YES;
        if (!ourWebhelperFix(dest)) { event(@"webhelper_fix_conflict", nil); return NO; }
    }
    NSString *incoming = [dest stringByAppendingString:@".incoming"];
    [fm removeItemAtPath:incoming error:nil];
    if (![fm copyItemAtPath:fix toPath:incoming error:nil] || rename(incoming.fileSystemRepresentation, dest.fileSystemRepresentation))
        fail(@"webhelper_fix_install_failed");
    event(@"webhelper_fix_installed", nil);
    return YES;
}
// Asks Steam to quit the way its own menu does, then makes sure the session has ended.
static void closeSteam(NSString *gameRunning) {
    if (!matches(state()[@"active_runtime"], RUNTIME_VERSION_PATTERN)) return;
    NSString *engine = runtime();
    NSArray *rows = sessionProcesses();
    if (gameRunning && running(rows, @"game")) fail(gameRunning);
    if (!rows.count) return;
    event(@"closing_steam", nil);
    if ([fm fileExistsAtPath:steamPath()]) task(join(engine, @"bin/wine"), @[steamPath(), @"-shutdown"], wineEnv(engine), @"steam-shutdown.log");
    for (int i = 0; i < 30; i++) {
        [NSThread sleepForTimeInterval:1]; [membershipCache removeAllObjects];
        if (!sessionProcesses().count) break;
    }
    endSession(engine);
}
/* Steam's installer is a silent NSIS installer. Steam then downloads the rest of itself the
 * first time it starts, Chromium web helper included, so setup starts it once and closes it
 * as soon as the web helper exists: the fix has to be beside the helper before it starts. */
static void installSteam(NSString *installer, NSString *expected, NSString *fixOption) {
    requireRosetta();
    NSString *engine = runtime(); if (busy(engine)) fail(@"close_steam_before_setup");
    if (![fm fileExistsAtPath:join(root, @"environment/system.reg")]) fail(@"prepare_environment_first");
    if (!matches(expected, @"^[a-f0-9]{64}$") || ![hashFile(installer) isEqual:expected]) fail(@"steam_installer_hash_mismatch");
    NSString *fix = bundledWebhelperFix(fixOption);
    if (![fm fileExistsAtPath:steamPath()]) {
        saveStage(@"installing_steam");
        if (wine(engine, @[installer, @"/S"], @"steam-installer.log", 600)) fail(@"steam_install_failed");
        if (!serverIdle(engine, 120)) fail(@"environment_initialization_busy");
        if (![fm fileExistsAtPath:steamPath()]) fail(@"steam_install_failed");
    }
    if (!installWebhelperFix(fix)) {
        saveStage(@"updating_steam");
        task(join(engine, @"bin/wine"), @[steamPath(), @"-silent"], wineEnv(engine), @"steam-first-start.log");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1800];
        BOOL helper = NO;
        while (!helper && deadline.timeIntervalSinceNow > 0 && !cancelRequested) {
            [NSThread sleepForTimeInterval:2];
            helper = running(sessionProcesses(), @"webhelper") && [fm fileExistsAtPath:join(webhelperFolder(), @"steamwebhelper.exe")];
        }
        closeSteam(nil);
        if (cancelRequested) fail(@"cancelled");
        if (!helper) fail(@"steam_update_failed");
        if (!installWebhelperFix(fix)) fail(@"webhelper_fix_install_failed");
    }
    saveStage(@"steam_ready");
}
/* Opens Steam, or brings it forward. With PLAY, Steam starts Raft (its own steam:// command;
 * a running Steam receives it from a second start, which hands it over and exits). */
static void launch(BOOL play, BOOL hud, NSString *fixOption) {
    requireRosetta();
    NSString *engine = runtime();
    if (![fm fileExistsAtPath:steamPath()]) fail(@"steam_not_installed");
    NSArray *processes = sessionProcesses();
    NSMutableDictionary *env = wineEnv(engine);
    // Apple's Metal Performance HUD; Steam starts Raft with its own environment, so the HUD
    // follows the session: it changes the next time Steam opens.
    if (hud) [env addEntriesFromDictionary:@{@"MTL_HUD_ENABLED":@"1", @"MTL_HUD_DISABLE_MENU_BAR":@"1"}];
    NSMutableArray *args = [@[steamPath()] mutableCopy];
    if (play) [args addObject:@"steam://rungameid/" RAFT_APP_ID];
    if (running(processes, @"steam")) {
        if (play && running(processes, @"game")) { event(@"session_existing", @{@"kind":@"game"}); return; }
        task(join(engine, @"bin/wine"), play ? args : @[steamPath(), @"steam://open/main"], env, @"steam-handover.log");
        event(@"session_existing", @{@"kind":@"steam"});
        return;
    }
    if (busy(engine)) endSession(engine);  // Wine services left behind by an earlier session.
    configureEnvironment(engine);
    if (!installWebhelperFix(bundledWebhelperFix(fixOption))) event(@"webhelper_fix_pending", nil);
    NSTask *p = task(join(engine, @"bin/wine"), args, env, @"steam.log");
    saveStage(@"steam_started"); event(@"steam_open", @{@"pid":@(p.processIdentifier)});
}
static NSDictionary *status(void) {
    NSMutableDictionary *s = state();
    BOOL fix = [fm fileExistsAtPath:join(webhelperFolder(), @"version.dll")] && ourWebhelperFix(join(webhelperFolder(), @"version.dll"));
    return @{@"state":s, @"steam_installed":@([fm fileExistsAtPath:steamPath()]), @"game_installed":@([fm fileExistsAtPath:raftPath()]),
             @"webhelper_fix":@(fix), @"free_bytes":@(freeBytes())};
}
static void uninstall(void) {
    // Everything this app created lives under the owned folder: the Wine environment holding
    // Steam and Raft, runtimes, downloads, logs and caches. Move, never delete: Put Back works.
    closeSteam(@"close_raft_before_uninstall");
    NSURL *trashed = nil;
    if (![fm trashItemAtURL:[NSURL fileURLWithPath:root] resultingItemURL:&trashed error:nil]) fail(@"uninstall_move_failed");
    event(@"uninstalled", @{@"trashed":trashed.path ?: @""});
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    fm = NSFileManager.defaultManager; signal(SIGTERM, cancelled); signal(SIGINT, cancelled);
    @try {
        if (argc < 2) fail(@"command_required");
        NSString *command = @(argv[1]); NSMutableDictionary *options = [NSMutableDictionary dictionary];
        for (int i = 2; i < argc; i += 2) {
            if (i + 1 >= argc || strncmp(argv[i], "--", 2)) fail(@"invalid_arguments");
            options[@(argv[i] + 2)] = @(argv[i + 1]);
        }
        NSString *defaultRoot = join([fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path, @"RecallRaft");
        monitorMode = [command isEqual:@"session"];
        ownRoot(options[@"root"] ?: defaultRoot);
        if ([command isEqual:@"preflight"]) preflight();
        else if ([command isEqual:@"status"]) event(@"status", status());
        else if ([command isEqual:@"session"]) event(@"session", @{@"processes":state()[@"active_runtime"] ? sessionProcesses() : @[]});
        else if ([command isEqual:@"install-runtime"])
            installRuntime(options[@"archive"] ?: download(options[@"url"], options[@"sha256"]), options[@"sha256"], options[@"version"], [options[@"repair"] isEqual:@"1"]);
        else if ([command isEqual:@"verify"]) { verifyRuntime(runtime(), state()[@"active_runtime"]); event(@"runtime_verified", nil); }
        else if ([command isEqual:@"prepare"]) prepare();
        else if ([command isEqual:@"install-steam"])
            installSteam(options[@"installer"] ?: download(options[@"url"], options[@"sha256"]), options[@"sha256"], options[@"webhelper-dll"]);
        // --play 1 starts Raft through Steam; --metal-hud 1 shows Apple's Metal Performance HUD.
        else if ([command isEqual:@"launch"]) launch([options[@"play"] isEqual:@"1"], [options[@"metal-hud"] isEqual:@"1"], options[@"webhelper-dll"]);
        else if ([command isEqual:@"close-steam"]) { closeSteam(@"close_raft_before_maintenance"); event(@"steam_closed", nil); }
        else if ([command isEqual:@"stop"]) { endSession(runtime()); event(@"environment_stopped", nil); }
        else if ([command isEqual:@"uninstall"]) uninstall();
        else fail(@"unknown_command");
        if (lockFD >= 0) close(lockFD);
        return 0;
    } @catch (NSException *exception) {
        if (cancelRequested && ownedPreparation) {
            // Nothing ran when this preparation began: stop only what it started.
            cancelRequested = 0;
            @try { endSession(runtime()); } @catch (NSException *ignored) { (void)ignored; }
        }
        event(@"error", @{@"code":[exception.name isEqual:@"SetupError"] ? exception.reason : @"unexpected_setup_error"});
        if (lockFD >= 0) close(lockFD);
        return 1;
    }
}}
