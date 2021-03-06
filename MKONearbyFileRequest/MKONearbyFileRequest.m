//
// MKONearbyFileRequest.m
//
// Copyright (c) 2015 Mathias Koehnke (http://www.mathiaskoehnke.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "MKONearbyFileRequest.h"
#import "UIAlertController+MKO.h"
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#if NFR_ENABLE_LOGGING != 0
    #define NSLog(...) NSLog(__VA_ARGS__)
#else
    #define NSLog(...)
#endif

///--------------------------------------------------
/// @name MKONearbyFileRequestOperation
///--------------------------------------------------

typedef void(^MKOAskPermissionBlock)(BOOL granted);

static CGFloat const kInvitationSendingTimeout              = 30.;
static CGFloat const kInvitationAcceptingTimeout            = 45.;

static NSString * const kServiceType                        = @"mko-filerequest";
static NSString * const kDiscoveryMetaKeyType               = @"discovery-type";
static NSString * const kDiscoveryMetaKeyTypeTransmission   = @"discovery-type-transmission";
static NSString * const kDiscoveryMetaKeyUUID               = @"discovery-uuid";

static NSString * const kErrorDomain                        = @"de.mathiaskoehnke.filerequest";
static NSUInteger const kFileMoveErrorCode                  = 999;
static NSUInteger const kConnectionToPeerLostErrorCode      = 998;
static NSUInteger const kOperationCancelled                 = 997;

///--------------------------------------------------
/// @name MKONearbyFileRequestOperation
///--------------------------------------------------

#define typeAsString(enum) [@[@"Upload Operation",@"Download Operation"] objectAtIndex:enum]

@protocol MKONearbyFileRequestOperationDelegate <NSObject>
@required
- (void)operationWantsToStartAdvertiser:(MKONearbyFileRequestOperation *)operation;
- (void)operationWantsToStopAdvertiser:(MKONearbyFileRequestOperation *)operation;
- (void)operationWantsToCancel:(MKONearbyFileRequestOperation *)operation;
@end

@interface MKONearbyFileRequestOperation ()
@property (nonatomic) MKONearbyFileRequestOperationType type;
@property (nonatomic, strong) MCPeerID *remotePeerID;
@property (nonatomic, strong) NSString *fileUUID;
@property (nonatomic, strong) NSProgress *processing;
@property (nonatomic, strong) MKOProgressBlock progressBlock;
@property (nonatomic, strong) MKOCompletionBlock completionBlock;
@property (nonatomic) float progress;
@property (nonatomic, getter=isRunning) BOOL running;
@property (nonatomic, weak) id<MKONearbyFileRequestOperationDelegate> delegate;
- (void)start;
- (void)stop;
@end

@implementation MKONearbyFileRequestOperation
- (void)start {
    [self setRunning:YES];
    if (self.type == MKONearbyFileRequestOperationTypeDownload) {
        [self.delegate operationWantsToStartAdvertiser:self];
    }
}

- (void)stop {
    @try {
        [self.processing removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
    }
    @catch (NSException * __unused exception) {}
    [self setRunning:NO];
    [self setCompletionBlock:nil];
    [self setProgressBlock:nil];
    [self setProcessing:nil];
    if (self.type == MKONearbyFileRequestOperationTypeDownload) {
        [self.delegate operationWantsToStopAdvertiser:self];
    }
}

- (void)cancel {
    [self.delegate operationWantsToCancel:self];
}

- (void)setRemotePeerID:(MCPeerID *)remotePeerID {
    [self willChangeValueForKey:@"remotePeer"];
    _remotePeerID = remotePeerID;
    [self didChangeValueForKey:@"remotePeer"];
}

- (void)setProcessing:(NSProgress *)processing {
    _processing = processing;
    [_processing addObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted)) options:0 context:nil];
}

- (NSString *)remotePeer {
    return self.remotePeerID.displayName;
}

- (NSDictionary *)discoveryInfo {
    return @{kDiscoveryMetaKeyType : kDiscoveryMetaKeyTypeTransmission,
             kDiscoveryMetaKeyUUID : self.fileUUID};
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ - File: %@", typeAsString(self.type), self.fileUUID];
}

#pragma mark - Progress

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:NSStringFromSelector(@selector(fractionCompleted))]) {
        NSLog(@"fractionCompleted: %f", self.processing.fractionCompleted);
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            strongSelf.progress = (float)strongSelf.processing.fractionCompleted;
            if (strongSelf.progressBlock) strongSelf.progressBlock(strongSelf, (float)strongSelf.processing.fractionCompleted);
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end


///--------------------------------------------------
/// @name MKONearbyFileRequestOperationQueue
///--------------------------------------------------

@interface MKONearbyFileRequestOperationQueue : NSObject
@property (nonatomic, strong) NSMutableArray *operations;
@property (nonatomic, strong) NSTimer *operationTimer;
@property (nonatomic, strong) dispatch_queue_t operationAccessQueue;
- (BOOL)addOperation:(MKONearbyFileRequestOperation *)operation;
- (BOOL)removeOperation:(MKONearbyFileRequestOperation *)operation;
- (void)removeAllOperations;
- (NSArray *)operationsInQueue:(MKONearbyFileRequestOperationType)type;
- (NSArray *)operationsNotStarted:(MKONearbyFileRequestOperationType)type;
- (NSArray *)operationsInProgress:(MKONearbyFileRequestOperationType)type;
- (MKONearbyFileRequestOperation *)operation:(MKONearbyFileRequestOperationType)type withPeerID:(MCPeerID *)peerID;
@end

@implementation MKONearbyFileRequestOperationQueue
- (instancetype)init {
    self = [super init];
    if (self) {
        _operations = [NSMutableArray array];
        _operationAccessQueue = dispatch_queue_create("com.mathiaskoehnke.nearbyFileRequest.operationAccessQeue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (BOOL)addOperation:(MKONearbyFileRequestOperation *)operation {
    if ([self canRun:operation]) {
        __weak __typeof__(self) weakSelf = self;
        dispatch_barrier_sync(_operationAccessQueue, ^{
            __typeof__(self) strongSelf = weakSelf;
            [strongSelf->_operations addObject:operation];
            NSLog(@"Number of operations: %lu", (unsigned long)[strongSelf->_operations count]);
        });
        return YES;
    }
    return NO;
}

- (BOOL)removeOperation:(MKONearbyFileRequestOperation *)operation {
    if (operation) {
        __weak __typeof__(self) weakSelf = self;
        dispatch_barrier_sync(_operationAccessQueue, ^{
            __typeof__(self) strongSelf = weakSelf;
            [strongSelf->_operations removeObject:operation];
            NSLog(@"Remaining operations: %lu", (unsigned long)[strongSelf->_operations count]);
        });
        return YES;
    }
    return NO;
}

- (void)removeAllOperations {
    __weak __typeof__(self) weakSelf = self;
    dispatch_barrier_sync(_operationAccessQueue, ^{
        __typeof__(self) strongSelf = weakSelf;
        [strongSelf->_operations removeAllObjects];
    });
}

- (NSArray *)operationsWithPredicate:(NSPredicate *)predicate {
    __block NSArray *operations;
    __weak __typeof__(self) weakSelf = self;
    dispatch_sync(_operationAccessQueue, ^{
        __typeof__(self) strongSelf = weakSelf;
        operations = [strongSelf.operations filteredArrayUsingPredicate:predicate];
    });
    return operations;
}

- (NSArray *)operationsInQueue:(MKONearbyFileRequestOperationType)type {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"type == %d", type];
    return [self operationsWithPredicate:predicate];
}

- (NSArray *)operationsInProgress:(MKONearbyFileRequestOperationType)type {
    return [self operationsInProgress:type fileUUID:nil];
}

- (NSArray *)operationsInProgress:(MKONearbyFileRequestOperationType)type fileUUID:(NSString *)fileUUID {
    NSPredicate *predicate;
    if (fileUUID) { predicate = [NSPredicate predicateWithFormat:@"isRunning == %d AND type == %d AND fileUUID == %@", YES, type, fileUUID]; }
    else { predicate = [NSPredicate predicateWithFormat:@"isRunning == %d AND type == %d", YES, type]; }
    return [self operationsWithPredicate:predicate];
}

- (NSArray *)operationsNotStarted:(MKONearbyFileRequestOperationType)type {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"isRunning == %d AND type == %d", NO, type];
    return [self operationsWithPredicate:predicate];
}

- (MKONearbyFileRequestOperation *)operation:(MKONearbyFileRequestOperationType)type withPeerID:(MCPeerID *)peerID {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"remotePeerID == %@ AND type == %d", peerID, type];
    return [[self operationsWithPredicate:predicate] firstObject];
}

- (BOOL)canRun:(MKONearbyFileRequestOperation *)operation {
    if (operation.type == MKONearbyFileRequestOperationTypeDownload) {
        return [self operationsInQueue:MKONearbyFileRequestOperationTypeUpload].count == 0;
    } else if (operation.type == MKONearbyFileRequestOperationTypeUpload) {
        return ([self operationsInQueue:MKONearbyFileRequestOperationTypeDownload].count == 0 &&
                [self operation:MKONearbyFileRequestOperationTypeUpload withPeerID:operation.remotePeerID] == nil);
    }
    return NO;
}

- (void)downloadOperationTimerFired:(NSTimer *)timer {
    #pragma unused(timer)
    if ([self operationsInProgress:MKONearbyFileRequestOperationTypeDownload].count == 0 &&
        [self operationsInQueue:MKONearbyFileRequestOperationTypeDownload].count > 0) {
        MKONearbyFileRequestOperation *operationToStart = [self operationsNotStarted:MKONearbyFileRequestOperationTypeDownload].firstObject;
        [operationToStart start];
        NSLog(@"Operation: %@ started.", operationToStart);
    }
}

- (void)startObserver {
    _operationTimer = [NSTimer scheduledTimerWithTimeInterval:5. target:self selector:@selector(downloadOperationTimerFired:)
                                                     userInfo:nil repeats:YES];
}

- (void)stopObserver {
    [self.operationTimer invalidate];
    [self setOperationTimer:nil];
}

@end


///--------------------------------------------------
/// @name MKONearbyFileRequest
///--------------------------------------------------

@interface MKONearbyFileRequest () <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, UIAlertViewDelegate, MKONearbyFileRequestOperationDelegate, NSFileManagerDelegate>
@property (nonatomic, strong) MCPeerID *peerID;
@property (nonatomic, strong) MCSession *session;
@property (nonatomic, strong) MCNearbyServiceAdvertiser *advertiser;
@property (nonatomic, strong) MCNearbyServiceBrowser *browser;
@property (nonatomic, getter=isRequestListening) BOOL requestListening;

@property (nonatomic, strong) id<MKOFileLocator> fileLocator;
@property (nonatomic, strong) MKONearbyFileRequestOperationQueue *operationQueue;

@property (nonatomic, strong) MKOProgressBlock uploadProgressBlock;
@property (nonatomic, strong) MKOCompletionBlock uploadCompletionBlock;
@property (nonatomic, strong) MKOPermissionBlock uploadPermissionBlock;

@property (nonatomic, strong) NSMutableArray *askPermissionCompletionBlocks;
@property (nonatomic, strong) dispatch_queue_t askPermissionCompletionBlocksAccessQueue;

@property (nonatomic, strong) NSFileManager *fileManager;

@property (nonatomic, strong) id willEnterForegroundNotificationObserver;
@property (nonatomic, strong) id didEnterBackgroundNotificationObserver;
@end

@implementation MKONearbyFileRequest

- (id)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Must use initWithDisplayName instead." userInfo:nil];
}

- (id)initWithDisplayName:(NSString *)displayName fileLocator:(id<MKOFileLocator>)fileLocator {
    self = [super init];
    if (self) {
        NSParameterAssert([displayName length] > 0);
        NSParameterAssert(fileLocator != nil);
        
        _displayName = displayName;
        _fileLocator = fileLocator;
        _operationQueue = [MKONearbyFileRequestOperationQueue new];
        _askPermissionCompletionBlocks = [NSMutableArray array];
        _askPermissionCompletionBlocksAccessQueue =
            dispatch_queue_create("com.mathiaskoehnke.nearbyFileRequest.askPermissionCompletionBlocksAccessQueue", DISPATCH_QUEUE_CONCURRENT);
        
        _fileManager = [NSFileManager new];
        _fileManager.delegate = self;
        
        [self setupSession];
        
        __weak __typeof__(self) weakSelf = self;
        _didEnterBackgroundNotificationObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                              object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            #pragma unused(note)
            NSLog(@"Entering Background...");
            BOOL isRequestListening = weakSelf.isRequestListening;
            [weakSelf tearDownSession];
            [weakSelf setRequestListening:isRequestListening];
        }];
        
        _willEnterForegroundNotificationObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            #pragma unused(note)
            NSLog(@"Entering Foreground...");
            [weakSelf setupSession];
            if (weakSelf.isRequestListening) [weakSelf startRequestListener];
        }];
    }
    return self;
}

- (void)setupSession {
    [self setPeerID:[[MCPeerID alloc] initWithDisplayName:self.displayName]];
    [self setSession:[[MCSession alloc] initWithPeer:self.peerID]];
    [self.session setDelegate:self];
    [self setBrowser:[[MCNearbyServiceBrowser alloc] initWithPeer:self.peerID serviceType:kServiceType]];
    [self.browser setDelegate:self];
}

- (void)tearDownSession {
    [self cancelAllOperations];
    [self stopRequestListener];
    [self stopAdvertiser];
    [self.browser setDelegate:nil];
    [self setBrowser:nil];
    [self.session setDelegate:nil];
    [self setSession:nil];
    [self setPeerID:nil];
}

- (void)cancelAllOperations {
    NSError *error = [NSError errorWithDomain:kErrorDomain code:kOperationCancelled userInfo:@{NSLocalizedDescriptionKey : @"The operation was cancelled."}];
    MKONearbyFileRequestOperation *downloadOperation = [self.operationQueue operationsInQueue:MKONearbyFileRequestOperationTypeDownload].firstObject;
    [self finishDownloadWithOperation:downloadOperation resource:downloadOperation.fileUUID url:nil error:error];
    
    NSArray *uploadOperations = [self.operationQueue operationsInQueue:MKONearbyFileRequestOperationTypeUpload];
    [uploadOperations enumerateObjectsUsingBlock:^(MKONearbyFileRequestOperation *uploadOperation, NSUInteger idx, BOOL *stop) {
        #pragma unused(idx, stop)
        [self finishUploadWithOperation:uploadOperation url:nil error:error];
    }];
    [self.operationQueue removeAllOperations];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.willEnterForegroundNotificationObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.didEnterBackgroundNotificationObserver];
    [self tearDownSession];
}

#pragma mark - MKONearbyFileRequestOperation Delegate

- (void)operationWantsToStartAdvertiser:(MKONearbyFileRequestOperation *)operation {
    [self startAdvertiserWithDiscoveryInfo:operation.discoveryInfo];
}

- (void)operationWantsToStopAdvertiser:(MKONearbyFileRequestOperation *)operation {
    #pragma unused(operation)
    [self stopAdvertiser];
}

- (void)operationWantsToCancel:(MKONearbyFileRequestOperation *)operation {
    [operation stop];
    [self.operationQueue removeOperation:operation];
    [self.session disconnect];
}

#pragma mark - Upload Blocks

- (void)setUploadCompletionBlock:(MKOCompletionBlock)block {
    __weak __typeof__(self) weakSelf = self;
    _uploadCompletionBlock = ^(MKONearbyFileRequestOperation *operation, NSURL *url, NSError *error) {
        __typeof__(self) strongSelf = weakSelf;
        NSArray *operations = [strongSelf.operationQueue operationsInProgress:MKONearbyFileRequestOperationTypeUpload fileUUID:operation.fileUUID];
        if (operations.count == 1 && block) block(operation, url, error);
    };
}

- (void)setUploadProgressBlock:(MKOProgressBlock)block {
    __weak __typeof__(self) weakSelf = self;
    _uploadProgressBlock = ^(MKONearbyFileRequestOperation *operation, float progress) {
        #pragma unused(progress)
        __typeof__(self) strongSelf = weakSelf;
        NSArray *operations = [strongSelf.operationQueue operationsInProgress:MKONearbyFileRequestOperationTypeUpload fileUUID:operation.fileUUID];
        CGFloat allFractionsCompleted = [[operations valueForKeyPath:@"@sum.processing.fractionCompleted"] floatValue];
        operation.progress = (float)allFractionsCompleted / operations.count;
        if (block) block(operation, operation.progress);
    };
}

# pragma mark - Request

- (void)startAdvertiserWithDiscoveryInfo:(NSDictionary *)discoveryInfo {
    NSLog(@"Starting Advertiser for Peer: %@", self.peerID.displayName);
    [self setAdvertiser:[[MCNearbyServiceAdvertiser alloc] initWithPeer:self.peerID discoveryInfo:discoveryInfo serviceType:kServiceType]];
    [self.advertiser setDelegate:self];
    [self.advertiser startAdvertisingPeer];
}

- (void)stopAdvertiser {
    NSLog(@"Stopping Advertiser ...");
    [self.advertiser stopAdvertisingPeer];
    [self.advertiser setDelegate:nil];
    [self setAdvertiser:nil];
}

- (BOOL)isAdvertising {
    return self.advertiser != nil;
}

- (void)startRequestListener {
    NSLog(@"Starting Browser for Peer: %@", self.peerID.displayName);
    [self.operationQueue startObserver];
    [self.browser startBrowsingForPeers];
    [self setRequestListening:YES];
}

- (void)stopRequestListener {
    NSLog(@"Stopping Browser ...");
    [self.operationQueue stopObserver];
    [self.browser stopBrowsingForPeers];
    [self setRequestListening:NO];
}

- (MKONearbyFileRequestOperation *)requestFile:(NSString *)uuid progress:(MKOProgressBlock)progress completion:(MKOCompletionBlock)completion {
    NSParameterAssert(completion != nil);
    
    MKONearbyFileRequestOperation *downloadOperation = [MKONearbyFileRequestOperation new];
    downloadOperation.type = MKONearbyFileRequestOperationTypeDownload;
    downloadOperation.fileUUID = uuid;
    downloadOperation.progressBlock = progress;
    downloadOperation.completionBlock = completion;
    downloadOperation.delegate = self;
    return [self.operationQueue addOperation:downloadOperation] ? downloadOperation : nil;
}

#pragma mark - Advertiser

- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error {
    if ([advertiser isEqual:self.advertiser]) {
        MKONearbyFileRequestOperation *currentDownloadOperation = [self currentDownloadOperation];
        dispatch_async(dispatch_get_main_queue(), ^{
            currentDownloadOperation.completionBlock(currentDownloadOperation, nil, error);
            [currentDownloadOperation stop];
            [self.operationQueue removeOperation:currentDownloadOperation];
        });
    }
}

- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didReceiveInvitationFromPeer:(MCPeerID *)peerID
       withContext:(NSData *)context invitationHandler:(void (^)(BOOL accept, MCSession *session))invitationHandler {
    if ([advertiser isEqual:self.advertiser]) {
        MKONearbyFileRequestOperation *currentDownloadOperation = [self currentDownloadOperation];
        NSDictionary *discoveryInfo = [NSKeyedUnarchiver unarchiveObjectWithData:context];
        if (currentDownloadOperation.remotePeerID == nil && [currentDownloadOperation.discoveryInfo isEqualToDictionary:discoveryInfo]) {
            NSLog(@"Found peer %@ for downloading file with UUID: %@", peerID.displayName, discoveryInfo[kDiscoveryMetaKeyUUID]);
            currentDownloadOperation.remotePeerID = peerID;
            invitationHandler(YES, self.session);
            
            /** Timeout within the browser has to connect to this advertiser, otherwise -> disconnect **/
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInvitationAcceptingTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                //NSLog(@"Checking if invitation acceptance was received by %@ ... ", peerID.displayName);
                if ([self isAdvertising] && [currentDownloadOperation isEqual:[self currentDownloadOperation]]) {
                    NSLog(@"Despite accepting an invitation, the remote peer (%@ = browser) did not start sending the file in time.\
                          Therefore we declare the peer as disconnected.", peerID.displayName);
                    NSError *error = [NSError errorWithDomain:kErrorDomain code:kConnectionToPeerLostErrorCode
                                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Connection to %@ lost.", peerID.displayName]}];
                    [self finishDownloadWithOperation:currentDownloadOperation resource:currentDownloadOperation.fileUUID url:nil error:error];
                }
            });
        } else {
            invitationHandler(NO, nil);
        }
    }
}

#pragma mark - Browser

- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error {
    if ([browser isEqual:self.browser]) {
        NSLog(@"Could not start browsing for peers: %@", [error localizedDescription]);
        [self stopRequestListener];
        if (self.uploadCompletionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.uploadCompletionBlock(nil, nil, error);
            });
        }
    }
}

- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peerID withDiscoveryInfo:(NSDictionary *)info {
    if ([browser isEqual:self.browser]) {
        NSLog(@"Found peer: %@ with info: %@", peerID.displayName, info);
        if ([info[kDiscoveryMetaKeyType] isEqualToString:kDiscoveryMetaKeyTypeTransmission]) {
            NSString *uuid = info[kDiscoveryMetaKeyUUID];
            NSLog(@"Lookup file with uuid: %@", uuid);
            BOOL fileExists = [self.fileLocator fileExists:uuid];
            
            if (fileExists && [self.operationQueue operationsInQueue:MKONearbyFileRequestOperationTypeDownload].count == 0) {
                NSLog(@"%@ is ready for sharing file %@ with %@", self.peerID, uuid, peerID);
                MKONearbyFileRequestOperation *uploadOperation = [MKONearbyFileRequestOperation new];
                uploadOperation.type = MKONearbyFileRequestOperationTypeUpload;
                uploadOperation.fileUUID = uuid;
                uploadOperation.remotePeerID = peerID;
                uploadOperation.progressBlock = self.uploadProgressBlock;
                uploadOperation.completionBlock = self.uploadCompletionBlock;
                uploadOperation.delegate = self;
                
                __weak __typeof__(self) weakSelf = self;
                void(^accessHandler)(BOOL accept) = ^(BOOL accept) {
                    __typeof__(self) strongSelf = weakSelf;
                    if (accept && [strongSelf.operationQueue addOperation:uploadOperation]) {
                        [uploadOperation start];
                        NSData *context = [NSKeyedArchiver archivedDataWithRootObject:uploadOperation.discoveryInfo];
                        [strongSelf.browser invitePeer:peerID toSession:strongSelf.session withContext:context timeout:kInvitationSendingTimeout];
                    }
                };
                NSLog(@"Asking User for permission");
                if (self.uploadPermissionBlock) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.uploadPermissionBlock(uploadOperation, uuid, accessHandler);
                    });
                } else {
                    [self askForPermission:uploadOperation completion:accessHandler];
                }
            }
        }
    }
}

- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peerID {
    if ([browser isEqual:self.browser]) {
        NSLog(@"Peer %@ stopped advertising.", peerID.displayName);
        /** Check if remote peer is already connected to this session. If yes, we don't handle a
         connection loss here. We wait for the peer to change the state to disconnected. **/
        if ([self.session.connectedPeers containsObject:peerID] == NO) {
            /** This is the case if a peer disconnected before this host could send out an invitation. **/
            NSError *error = [NSError errorWithDomain:kErrorDomain code:kConnectionToPeerLostErrorCode
                                             userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Connection to %@ lost.", peerID.displayName]}];
            MKONearbyFileRequestOperation *uploadOperation = [self.operationQueue operation:MKONearbyFileRequestOperationTypeUpload withPeerID:peerID];
            if (uploadOperation) {
                NSLog(@"Peer %@ is not connected yet. Hence we disconnect manually.", peerID.displayName);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (uploadOperation.completionBlock)
                        uploadOperation.completionBlock(uploadOperation, nil, error);
                    [uploadOperation stop];
                    [self.operationQueue removeOperation:uploadOperation];
                });
            }
        }
    }
}


#pragma mark - Session

- (void)session:(MCSession *)session peer:(MCPeerID *)peerID didChangeState:(MCSessionState)state {
    if ([session isEqual:self.session]) {
        if (state == MCSessionStateConnected) {
            NSLog(@"Peer %@ did connect to session.", peerID.displayName);
            
            /** Handle Upload Operation Peer Connect **/
            MKONearbyFileRequestOperation *uploadOperation = [self.operationQueue operation:MKONearbyFileRequestOperationTypeUpload withPeerID:peerID];
            if (uploadOperation) {
                if (self.uploadProgressBlock) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.uploadProgressBlock(uploadOperation, 0.);
                    });
                }
                
                /** Sending file to connected Peer **/
                NSURL *fileToSend = [self.fileLocator fileWithUUID:uploadOperation.fileUUID];
                uploadOperation.processing = [self.session sendResourceAtURL:fileToSend withName:uploadOperation.fileUUID toPeer:peerID withCompletionHandler:^(NSError *error) {
                    [self finishUploadWithOperation:uploadOperation url:fileToSend error:error];
                }];
            }
        } else if (state == MCSessionStateNotConnected) {
            NSLog(@"Peer %@ did disconnect from session.", peerID.displayName);
            MKONearbyFileRequestOperation *uploadOperation = [self.operationQueue operation:MKONearbyFileRequestOperationTypeUpload withPeerID:peerID];
            if (uploadOperation && uploadOperation.processing.fractionCompleted < 1.) {
                /** This is the case if a peer was invited by this host but it never responded to the invitation **/
                NSLog(@"It seems that peer %@ disconnected before the file was transmitted completely. Aborting ...", peerID.displayName);
                NSError *error = [NSError errorWithDomain:kErrorDomain code:kConnectionToPeerLostErrorCode
                                                 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Connection to %@ lost.", peerID.displayName]}];
                [self finishUploadWithOperation:uploadOperation url:nil error:error];
            }
        } else if (state == MCSessionStateConnecting) {
            NSLog(@"Peer %@ will connect to session.", peerID.displayName);
        }
    }
}

- (void)finishUploadWithOperation:(MKONearbyFileRequestOperation *)operation url:(NSURL *)url error:(NSError *)error {
    NSLog(@"Sending completed: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.uploadCompletionBlock) {
            self.uploadCompletionBlock(operation, url, error);
        }
        [operation stop];
        [self.operationQueue removeOperation:operation];
    });
}

- (void)finishDownloadWithOperation:(MKONearbyFileRequestOperation *)operation resource:(NSString *)resource url:(NSURL *)url error:(NSError *)error {
    NSLog(@"Calling session disconnect.");
    [self.session disconnect];
    
    __block MKOCompletionBlock completion = operation.completionBlock;
    [operation stop];
    [self.operationQueue removeOperation:operation];
    
    NSURL *permanentLocation;
    NSError *fileMoveError;
    if (error == nil && url != nil) {
        /** Movie file to permanent location **/
        permanentLocation = [self moveFileWithName:resource toPermanentLocationFromTemporaryLocation:url];
        if (permanentLocation == nil) {
            fileMoveError = [NSError errorWithDomain:kErrorDomain code:kFileMoveErrorCode
                                            userInfo:@{NSLocalizedDescriptionKey : @"Could not move file into permanent location."}];
        }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(operation, permanentLocation, error? : fileMoveError);
        completion = nil;
    });
}

- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)resourceName fromPeer:(MCPeerID *)peerID withProgress:(NSProgress *)progress {
    if ([session isEqual:self.session]) {
        NSLog(@"didStartReceivingResourceWithName: %@ from peer: %@", resourceName, peerID.displayName);
        MKONearbyFileRequestOperation *currentDownloadOperation = [self currentDownloadOperation];
        if (currentDownloadOperation && [currentDownloadOperation.remotePeerID isEqual:peerID]) {
            NSLog(@"%@ will stop advertising ...", self.peerID.displayName);
            [self stopAdvertiser];
            currentDownloadOperation.processing = progress;
            if (currentDownloadOperation.progressBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    currentDownloadOperation.progressBlock(currentDownloadOperation, 0.);
                });
            }
        } else {
            NSLog(@"Something went wrong. Did start receiving file from peer that is not linked to current download operation.");
        }
    }
}

- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)resourceName fromPeer:(MCPeerID *)peerID atURL:(NSURL *)localURL withError:(NSError *)error {
    if ([session isEqual:self.session]) {
        NSLog(@"didFinishReceivingResourceWithName: %@ from peer: %@", resourceName, peerID.displayName);
        MKONearbyFileRequestOperation *currentDownloadOperation = [self currentDownloadOperation];
        if (currentDownloadOperation && [currentDownloadOperation.remotePeerID isEqual:peerID]) {
            [self finishDownloadWithOperation:currentDownloadOperation resource:resourceName url:localURL error:error];
        } else {
            NSLog(@"Something went wrong. Did receive file from peer that is not linked to current download operation.");
        }
    }
}

#pragma mark  - NSFileManager

- (NSURL *)moveFileWithName:(NSString *)fileName toPermanentLocationFromTemporaryLocation:(NSURL *)temporaryLocation {
    NSURL *documentsFolder = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSString *permanentPath = [documentsFolder.path stringByAppendingPathComponent:fileName];
    NSURL *permanentLocation = [NSURL fileURLWithPath:permanentPath];
    NSError *moveFileError;
    NSLog(@"Moving file %@ from %@ to permanent location ... ", fileName, temporaryLocation);
    [self.fileManager moveItemAtURL:temporaryLocation toURL:permanentLocation error:&moveFileError];
    if (moveFileError) {
        NSLog(@"Could not move file to permanent location: %@", [moveFileError localizedDescription]);
        return nil;
    }
    return permanentLocation;
}

-(BOOL)fileManager:(NSFileManager *)fileManager shouldProceedAfterError:(NSError *)error movingItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL {
    #pragma unused(fileManager, srcURL, dstURL)
    return ([error code] == NSFileWriteFileExistsError);
}

- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream withName:(NSString *)streamName fromPeer:(MCPeerID *)peerID {
    #pragma unused(session, stream, streamName, peerID)
}
- (void)session:(MCSession *)session didReceiveData:(NSData *)data fromPeer:(MCPeerID *)peerID {
    #pragma unused(session, data, peerID)
}

#pragma mark - Helper Methods

- (void)askForPermission:(MKONearbyFileRequestOperation *)operation completion:(MKOAskPermissionBlock)completion {
    dispatch_async(dispatch_get_main_queue(), ^{        
        NSString *message = [NSString stringWithFormat:@"%@ would like to download\n%@\nfrom your device.", operation.remotePeer, operation.fileUUID];
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Upload File"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Don't allow" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
            #pragma unused(action)
            if (completion) completion(NO);
        }];
        
        UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Allow" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            #pragma unused(action)
            if (completion) completion(YES);
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:defaultAction];
        [alert show];
    });
}

- (MKONearbyFileRequestOperation *)currentDownloadOperation {
    return [self.operationQueue operationsInProgress:MKONearbyFileRequestOperationTypeDownload].firstObject;
}

@end
