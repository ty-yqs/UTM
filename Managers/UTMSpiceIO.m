//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "UTMSpiceIO.h"
#import "UTMConfiguration.h"
#import "UTMConfiguration+Miscellaneous.h"
#import "UTMConfiguration+Sharing.h"
#import "UTMLogging.h"
#import "UTMViewState.h"
#import "CocoaSpice.h"

extern BOOL isPortAvailable(NSInteger port); // from UTMPortAllocator
extern NSString *const kUTMErrorDomain;
static const int kMaxConnectionTries = 30; // qemu needs to start spice server first
static const int64_t kRetryWait = (int64_t)1*NSEC_PER_SEC;

typedef void (^doConnect_t)(void);
typedef void (^connectionCallback_t)(BOOL success, NSString * _Nullable msg);

@interface UTMSpiceIO ()

@property (nonatomic, readwrite, nullable) CSDisplayMetal *primaryDisplay;
@property (nonatomic, readwrite, nullable) CSInput *primaryInput;
#if !defined(WITH_QEMU_TCI)
@property (nonatomic, readwrite, nullable) CSUSBManager *primaryUsbManager;
#endif
@property (nonatomic, nullable) doConnect_t doConnect;
@property (nonatomic, nullable) connectionCallback_t connectionCallback;
@property (nonatomic, nullable) CSConnection *spiceConnection;
@property (nonatomic, nullable) CSMain *spice;
@property (nonatomic, nullable, copy) NSURL *sharedDirectory;
@property (nonatomic) NSInteger port;
@property (nonatomic) BOOL dynamicResolutionSupported;

@end

@implementation UTMSpiceIO

- (instancetype)initWithConfiguration:(UTMConfiguration *)configuration port:(NSInteger)port {
    if (self = [super init]) {
        _configuration = configuration;
        _port = port;
    }
    
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (void)initializeSpiceIfNeeded {
    @synchronized (self) {
        if (!self.spiceConnection) {
            self.spiceConnection = [[CSConnection alloc] initWithHost:@"127.0.0.1" port:[NSString stringWithFormat:@"%lu", self.port]];
            self.spiceConnection.delegate = self;
            self.spiceConnection.audioEnabled = _configuration.soundEnabled;
            self.spiceConnection.session.shareClipboard = _configuration.shareClipboardEnabled;
        }
    }
}

- (BOOL)isSpiceInitialized {
    @synchronized (self) {
        return self.spice != nil && self.spiceConnection != nil;
    }
}

#pragma mark - UTMInputOutput

- (BOOL)startWithError:(NSError **)err {
    @synchronized (self) {
        if (!self.spice) {
            self.spice = [CSMain sharedInstance];
        }
        if (![self.spice spiceStart]) {
            // error
            return NO;
        }
    }
    [self initializeSpiceIfNeeded];
    
    return YES;
}

- (void)connectWithCompletion:(void(^)(BOOL, NSString * _Nullable))block {
    __block int tries = kMaxConnectionTries;
    __block __weak doConnect_t weakDoConnect;
    __weak UTMSpiceIO *weakSelf = self;
    self.doConnect = ^{
        if (weakSelf && tries-- > 0) {
            if (!isPortAvailable(weakSelf.port)) { // port is in use, try connecting
                @synchronized (weakSelf) {
                    if ([weakSelf.spiceConnection connect]) {
                        weakSelf.connectionCallback = block;
                        weakSelf.doConnect = nil;
                        return;
                    }
                }
            } else {
                UTMLog(@"SPICE port not in use yet, retries left: %d", tries);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRetryWait), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), weakDoConnect);
                return;
            }
        }
        if (tries == 0) {
            // if we get here, error is unrecoverable
            block(NO, NSLocalizedString(@"Failed to connect to SPICE server.", "UTMSpiceIO"));
        }
        weakSelf.connectionCallback = nil;
        weakSelf.doConnect = nil;
    };
    weakDoConnect = self.doConnect;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), self.doConnect);
}

- (void)disconnect {
    @synchronized (self) {
        [self endSharingDirectory];
        [self.spiceConnection disconnect];
        self.spiceConnection.delegate = nil;
        self.spiceConnection = nil;
        self.spice = nil;
    }
    self.primaryDisplay = nil;
    self.primaryInput = nil;
#if !defined(WITH_QEMU_TCI)
    self.primaryUsbManager = nil;
#endif
    self.doConnect = nil;
}

- (UTMScreenshot *)screenshot {
    return [self.primaryDisplay screenshot];
}

- (void)setDebugMode:(BOOL)debugMode {
    @synchronized (self) {
        [self.spice spiceSetDebug: debugMode];
    }
}

- (void)syncViewState:(UTMViewState *)viewState {
    viewState.displayOriginX = self.primaryDisplay.viewportOrigin.x;
    viewState.displayOriginY = self.primaryDisplay.viewportOrigin.y;
    viewState.displaySizeWidth = self.primaryDisplay.displaySize.width;
    viewState.displaySizeHeight = self.primaryDisplay.displaySize.height;
    viewState.displayScale = self.primaryDisplay.viewportScale;
}

- (void)restoreViewState:(UTMViewState *)viewState {
    self.primaryDisplay.viewportOrigin = CGPointMake(viewState.displayOriginX, viewState.displayOriginY);
    self.primaryDisplay.displaySize = CGSizeMake(viewState.displaySizeWidth, viewState.displaySizeHeight);
    if (viewState.displayScale) { // cannot be zero
        self.primaryDisplay.viewportScale = viewState.displayScale;
    } else {
        self.primaryDisplay.viewportScale = 1.0; // default value
    }
}

#pragma mark - CSConnectionDelegate

- (void)spiceConnected:(CSConnection *)connection {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    self.primaryInput = connection.input;
    [self.delegate spiceDidChangeInput:connection.input];
#if !defined(WITH_QEMU_TCI)
    self.primaryUsbManager = connection.usbManager;
    [self.delegate spiceDidChangeUsbManager:connection.usbManager];
#endif
}

- (void)spiceDisconnected:(CSConnection *)connection {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
}

- (void)spiceError:(CSConnection *)connection err:(NSString *)msg {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    if (self.connectionCallback) {
        self.connectionCallback(NO, msg);
        self.connectionCallback = nil;
    }
}

- (void)spiceDisplayCreated:(CSConnection *)connection display:(CSDisplayMetal *)display {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    [self.delegate spiceDidCreateDisplay:display];
    if (display.channelID == 0 && display.monitorID == 0) {
        self.primaryDisplay = display;
        if (self.connectionCallback) {
            self.connectionCallback(YES, nil);
            self.connectionCallback = nil;
        }
    }
}

- (void)spiceDisplayDestroyed:(CSConnection *)connection display:(CSDisplayMetal *)display {
    NSAssert(connection == self.spiceConnection, @"Unknown connection");
    [self.delegate spiceDidDestroyDisplay:display];
}

- (void)spiceAgentConnected:(CSConnection *)connection supportingFeatures:(CSConnectionAgentFeature)features {
    self.dynamicResolutionSupported = (features & kCSConnectionAgentFeatureMonitorsConfig) != kCSConnectionAgentFeatureNone;
}

- (void)spiceAgentDisconnected:(CSConnection *)connection {
    self.dynamicResolutionSupported = NO;
}

#pragma mark - Shared Directory

- (void)changeSharedDirectory:(NSURL *)url {
    if (self.sharedDirectory) {
        [self endSharingDirectory];
    }
    self.sharedDirectory = url;
    [self startSharingDirectory];
}

- (void)startSharingDirectory {
    if (self.sharedDirectory) {
        UTMLog(@"setting share directory to %@", self.sharedDirectory.path);
        [self.sharedDirectory startAccessingSecurityScopedResource];
        [self.spiceConnection.session setSharedDirectory:self.sharedDirectory.path readOnly:self.configuration.shareDirectoryReadOnly];
    }
}

- (void)endSharingDirectory {
    if (self.sharedDirectory) {
        [self.sharedDirectory stopAccessingSecurityScopedResource];
        self.sharedDirectory = nil;
        UTMLog(@"ended share directory sharing");
    }
}

#pragma mark - Properties

- (void)setDelegate:(id<UTMSpiceIODelegate>)delegate {
    _delegate = delegate;
    // make sure to send initial data
    if (self.primaryInput) {
        [self.delegate spiceDidChangeInput:self.primaryInput];
    }
    if (self.primaryDisplay) {
        [self.delegate spiceDidCreateDisplay:self.primaryDisplay];
    }
    for (CSDisplayMetal *display in self.spiceConnection.monitors) {
        if (display != self.primaryDisplay) {
            [self.delegate spiceDidCreateDisplay:display];
        }
    }
#if !defined(WITH_QEMU_TCI)
    if (self.primaryUsbManager) {
        [self.delegate spiceDidChangeUsbManager:self.primaryUsbManager];
    }
#endif
    if ([self.delegate respondsToSelector:@selector(spiceDynamicResolutionSupportDidChange:)]) {
        [self.delegate spiceDynamicResolutionSupportDidChange:self.dynamicResolutionSupported];
    }
}

- (void)setDynamicResolutionSupported:(BOOL)dynamicResolutionSupported {
    if (_dynamicResolutionSupported != dynamicResolutionSupported) {
        if ([self.delegate respondsToSelector:@selector(spiceDynamicResolutionSupportDidChange:)]) {
            [self.delegate spiceDynamicResolutionSupportDidChange:dynamicResolutionSupported];
        }
    }
    _dynamicResolutionSupported = dynamicResolutionSupported;
}

@end
