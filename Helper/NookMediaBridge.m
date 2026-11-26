// NookMediaBridge: tiny dylib loaded by /usr/bin/perl (an Apple platform binary that
// macOS still allows to read MediaRemote) to stream Now Playing info as JSON lines.
//   nook_stream : prints one JSON object per change to stdout, runs forever.
//   nook_send   : sends the MediaRemote command number in env NOOK_MR_COMMAND, then returns.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef NSString *(*ClientParentBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(int, NSDictionary *);

static void *mr;
static GetInfoFn getInfo;
static GetIsPlayingFn getIsPlaying;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
static ClientParentBundleFn clientParentBundle;

static BOOL loadMR(void) {
    if (mr) return YES;
    mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mr) return NO;
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (GetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (GetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = (ClientParentBundleFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    return getInfo != NULL;
}

static id jsonSafe(id v) {
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    if ([v isKindOfClass:[NSData class]]) return [(NSData *)v base64EncodedStringWithOptions:0];
    return nil;
}

static NSString *lastArtworkKey;

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        void (^finish)(NSString *) = ^(NSString *bundle) {
            getIsPlaying(q, ^(BOOL playing) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                if (bundle) out[@"bundle"] = bundle;
                NSDictionary *map = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
                    @"kMRMediaRemoteNowPlayingInfoTimestamp": @"timestamp",
                    @"kMRMediaRemoteNowPlayingInfoShuffleMode": @"shuffle",
                    @"kMRMediaRemoteNowPlayingInfoRepeatMode": @"repeat",
                };
                for (NSString *k in map) { id v = jsonSafe(info[k]); if (v) out[map[k]] = v; }
                // Only send artwork when the track changes (it is large).
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@", out[@"title"], out[@"artist"], out[@"album"]];
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:[NSData class]] && art.length > 0 && ![key isEqualToString:lastArtworkKey]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtworkKey = key;
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
                if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
            });
        };
        if (getClient && clientBundle) {
            getClient(q, ^(id client) {
                NSString *b = nil;
                if (client) {
                    if (clientParentBundle) b = clientParentBundle(client);
                    if (!b.length) b = clientBundle(client);
                }
                finish(b);
            });
        } else finish(nil);
    });
}

__attribute__((visibility("default"))) void nook_stream(void *a, void *b) {
    if (!loadMR()) { fprintf(stderr, "MediaRemote unavailable\n"); return; }
    RegisterFn reg = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { emit(); }];
    }
    // Periodic refresh as a safety net (keeps elapsed time in sync, detects stalls).
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { emit(); }];
    emit();
    CFRunLoopRun();
}

__attribute__((visibility("default"))) void nook_send(void *a, void *b) {
    if (!loadMR()) return;
    SendFn sendCmd = (SendFn)dlsym(mr, "MRMediaRemoteSendCommand");
    const char *c = getenv("NOOK_MR_COMMAND");
    if (sendCmd && c) sendCmd(atoi(c), nil);
    // Give the command a moment to be delivered before perl exits.
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
}
