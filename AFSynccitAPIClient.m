
#import "AFSynccitAPIClient.h"
#import "AFJSONRequestOperation.h"

NSString * const kAFRSynccitAPIBaseURLString = @"http://api.synccit.com/";

@interface AFSynccitAPIClient ()
@property NSTimer *updateTimer;
@property NSMutableArray *linkIdsToUpload;
@property AFHTTPRequestOperation* uploadOperation;

@property NSUInteger lastDownloadSyncOffset;
@property NSUInteger downloadFailureCount;
@property AFHTTPRequestOperation *downloadOperation;

@property BOOL isReachable;
@end

@implementation AFSynccitAPIClient

+ (AFSynccitAPIClient *)sharedClient {
    static AFSynccitAPIClient *_sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedClient = [[[self class] alloc] initWithBaseURL:[NSURL URLWithString:kAFRSynccitAPIBaseURLString]];
    });
    
    return _sharedClient;
}

- (id)initWithBaseURL:(NSURL *)url {
    self = [super initWithBaseURL:url];
    if (!self) {
        return nil;
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActiveNotification)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActiveNotification)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reachabilityDidChange:)
                                                 name:AFNetworkingReachabilityDidChangeNotification
                                               object:nil];
    
    self.linkIdsToUpload = [NSMutableArray array];
    [self registerHTTPOperationClass:[AFJSONRequestOperation class]];
    [self setDefaultHeader:@"Accept" value:@"application/json"];
    
    return self;
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(BOOL) isEnabled
{
    return self.username != nil && self.authCode != nil;
}

-(void) updateTimerFireMethod:(NSTimer*)timer
{
#if TARGET_IPHONE_SIMULATOR
    DLog(@"Ignoring Synccit sync");
#else
    DLog(@"Synccit update fired");
#endif
    
    [self uploadLinks];
    [self downloadLinks];
}

-(void) setUsername:(NSString*)username authCode:(NSString*)authCode
{
    self.username = username;
    self.authCode = authCode;
}

#pragma mark - Upload

-(void) uploadLinks
{
    if (self.linkIdsToUpload.count == 0 || self.uploadOperation != nil) {
        return;
    }
    
    NSArray *linkIdsSynccing = [self.linkIdsToUpload copy];
    [self.linkIdsToUpload removeAllObjects];
    
    NSDictionary *jsonDictionary = [self requestJSONWithLinks:linkIdsSynccing mode:@"update"];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSDictionary* parameters = @{@"type": @"json", @"data" : jsonString};
    
    void (^finally)(void) = ^{
        self.uploadOperation = nil;
    };
    
    void (^success)(AFHTTPRequestOperation *successOperation, NSDictionary*successJsonDictionary) =
    ^(AFHTTPRequestOperation *successOperation, NSDictionary* successJsonDictionary)
    {
        if(![successJsonDictionary isKindOfClass:[NSDictionary class]]){
            DLog(@"synccit API update returned non json");
            return;
        }
        
        if (successJsonDictionary[@"error"] != nil) {
            DLog(@"synccit API update returned error %@", successJsonDictionary[@"error"]);
            return;
        }
        DLog(@"synccit API update success.");
        finally();
    };
    
    void (^failure)(AFHTTPRequestOperation *, NSError *) = ^(AFHTTPRequestOperation *failOp, NSError *failError)
    {
        //retry on HTTP failure
        [self.linkIdsToUpload addObjectsFromArray:linkIdsSynccing];
        
        finally();
        DLog(@"synccit API update failed %@", error);
    };
    
    
	NSURLRequest *request = [self requestWithMethod:@"POST" path:@"api.php" parameters:parameters];
	self.uploadOperation = [self HTTPRequestOperationWithRequest:request success:success failure:failure];
    [self enqueueHTTPRequestOperation:self.uploadOperation];
}


-(void) addLinkId:(NSString*)linkId
{
    [self addLinkId:linkId commentsCount:nil linkRead:YES commentsRead:NO];
}

-(void) addLinkId:(NSString*)linkId
    commentsCount:(NSString*)commentsCount
         linkRead:(BOOL)linkRead
     commentsRead:(BOOL)commentsRead
{
    if (linkId == nil) {
        return;
    }
    if (self.username == nil || self.authCode == nil ) {
        return;
    }
    NSMutableDictionary *payLoad = [NSMutableDictionary dictionary];
    payLoad[@"id"] = linkId;
    if (commentsCount) {
        payLoad[@"comments"] = commentsCount;
    }
    if (linkRead && commentsRead) {
        payLoad[@"both"] = @(YES);
    }
    
    [self.linkIdsToUpload addObject:@{@"id": linkId}];
}

#pragma mark - Download

-(void) downloadLinks
{
    if (self.downloadOperation == nil) {
        _lastDownloadSyncDate = _lastDownloadSyncDate ?: [self last48HoursDate];
        _lastDownloadSyncOffset = 0;
        _downloadFailureCount = 0;
        [self nextDownloadOperation];
    }
}

NSString *const AFSynccitAPIClientNotificationNewLinks = @"AFSynccitAPIClientNotificationNewLinks";
NSString *const AFSynccitAPIClientLinksDownloadedUserInfoKey = @"AFSynccitAPIClientLinksDownloadedUserInfoKey";

- (void) notificationForLinks:(NSArray*)links
{
    NSDictionary *userInfo;
    if (links) {
        userInfo = @{AFSynccitAPIClientLinksDownloadedUserInfoKey:links};
    }
    NSNotification *notification = [NSNotification notificationWithName:AFSynccitAPIClientNotificationNewLinks
                                                                 object:self
                                                               userInfo:userInfo];
    NSNotificationCenter *notifier = [NSNotificationCenter defaultCenter];
    [notifier postNotification:notification];
}

- (void) completeDownloadOperation
{
    _downloadOperation = nil;
    
    //Additional 10 second buffer
    _lastDownloadSyncDate = [NSDate dateWithTimeIntervalSinceNow:-10];
}

static NSInteger kMaxSynccitHistorySize = 100;

- (void) nextDownloadOperation
{
    void (^getNextLinksBatch)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self nextDownloadOperation];
        });
    };
    
    if (_downloadFailureCount>3) {
        DLog(@"Failed too many times, cancelling");
        return;
    }
    
    _downloadOperation =
    [self linksSinceDate:_lastDownloadSyncDate
                  offset:_lastDownloadSyncOffset
                 success:^(AFHTTPRequestOperation *operation, NSArray *linkStatuses) {
                     self.lastDownloadSyncOffset += linkStatuses.count;
                     
                     if (linkStatuses.count == kMaxSynccitHistorySize) {
                         getNextLinksBatch();
                     } else {
                         DLog(@"completed with %d links updated",self.lastDownloadSyncOffset);
                         [self completeDownloadOperation];
                     }
                     
                     if (linkStatuses.count>0) {
                         [self notificationForLinks:linkStatuses];
                     }
                     
                 } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                     DLog(@"linksSinceDate: operation failed with error %@",error);
                     self.downloadFailureCount++;
                     getNextLinksBatch();
                 }];
}


-(void) statusForLinkIds:(NSArray*)linkIds
                 success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                 failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    if (self.username == nil || self.authCode == nil) {
        NSAssert(NO, @"Call isEnabled first, not logged in");
        if(failure) failure(nil, [self errorWithDescription:@"not logged in"]);
    }
    
    NSDictionary *jsonDictionary = [self requestJSONWithLinks:[self linkIdsDictionariesForLinkIds:linkIds] mode:@"read"];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSDictionary* parameters = @{@"type": @"json", @"data" : jsonString};
    
    
    void (^successWrapper)(AFHTTPRequestOperation *_operation, id json) =
    ^(AFHTTPRequestOperation *_operation, id json)
    {
        if([json isKindOfClass:[NSDictionary class]] && json[@"error"] != nil ){
            NSString *error = [NSString stringWithFormat:@"Synccit returned error: %@",json[@"error"]];
            if(failure) failure(_operation,[self errorWithDescription:error]);
            return;
        }
        
        if(![json isKindOfClass:[NSArray class]]){
            if(failure) failure(_operation,[self errorWithDescription:@"Malformed response"]);
            return;
        }
        
        
        if(success) {
            NSArray *linkIds = [self linkIdsArrayDictionary:json];
            success(_operation,linkIds);
            DLog(@"synccit API update success %@", [linkIds componentsJoinedByString:@","]);
        }
    };
    
    void (^failureWrapper)(AFHTTPRequestOperation *, NSError *) = ^(AFHTTPRequestOperation *_operation, NSError *_error)
    {
        if(failure) failure(_operation,_error);
        DLog(@"synccit API update failed %@", error);
    };
    
	NSURLRequest *request = [self requestWithMethod:@"POST" path:@"api.php" parameters:parameters];
	AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:successWrapper failure:failureWrapper];
    [self enqueueHTTPRequestOperation:operation];
}

-(void) statusForRedditAPIResponse:(NSDictionary*)redditAPIResponse
                           visited:(void (^)(NSArray *visitedLinkData))visited;

{
    if (self.username == nil || self.authCode == nil) {
        DLog(@"Not logged in, ignoring");
        return;
    }
    
    NSArray *children = [redditAPIResponse valueForKeyPath:@"data.children"];
    NSMutableArray *childrenIds = [NSMutableArray arrayWithCapacity:children.count];
    for (NSDictionary* data in children) {
        NSString *linkId = [data valueForKeyPath:@"data.id"];
        if (linkId) {
            [childrenIds addObject:linkId];
        }
    }
    [self statusForLinkIds:childrenIds success:^(AFHTTPRequestOperation *operation, NSArray *linkStatuses) {
        if (visited) {
            visited(linkStatuses);
        }
    } failure:nil];
}

-(AFHTTPRequestOperation*) linksSinceDate:(NSDate*)date
                                   offset:(NSInteger)offset
                                  success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                                  failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    if (self.username == nil || self.authCode == nil) {
        NSAssert(NO, @"Call isEnabled first, not logged in");
        if(failure) failure(nil, [self errorWithDescription:@"not logged in"]);
    }
    
    NSDictionary *jsonDictionary = [self requestJSONWithHistorySinceDate:date offset:offset];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSDictionary* parameters = @{@"type": @"json", @"data" : jsonString};
    DLog(@"Synccit payload %@",parameters);
    
    void (^successWrapper)(AFHTTPRequestOperation *_operation, id json) =
    ^(AFHTTPRequestOperation *_operation, id json)
    {
        if([json isKindOfClass:[NSDictionary class]] && json[@"error"] != nil ){
            NSString *error = [NSString stringWithFormat:@"Synccit returned error: %@",json[@"error"]];
            if(failure) failure(_operation,[self errorWithDescription:error]);
            return;
        }
        
        if(![json isKindOfClass:[NSArray class]]){
            if(failure) failure(_operation,[self errorWithDescription:@"Malformed response"]);
            return;
        }
        
        if(success) {
            NSArray *linkIds = [self linkIdsArrayDictionary:json];
            success(_operation,linkIds);
            DLog(@"synccit API update success %@", [linkIds componentsJoinedByString:@","]);
        }
    };
    
    void (^failureWrapper)(AFHTTPRequestOperation *, NSError *) = ^(AFHTTPRequestOperation *_operation, NSError *_error)
    {
        if(failure) failure(_operation,_error);
        DLog(@"synccit API update failed %@", error);
    };
    
	NSURLRequest *request = [self requestWithMethod:@"POST" path:@"api.php" parameters:parameters];
	AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:successWrapper failure:failureWrapper];
    [self enqueueHTTPRequestOperation:operation];
    return operation;
}

#pragma mark - Helpers

- (NSDate*) last48HoursDate {
    NSTimeInterval hours48 = 60.*60.*48.*-1;
    return [NSDate dateWithTimeIntervalSinceNow:hours48];
}

-(NSArray*) linkIdsArrayDictionary:(NSArray*)linkIdsDictionaries
{
    NSMutableArray *linkIds = [NSMutableArray arrayWithCapacity:linkIdsDictionaries.count];
    for (NSDictionary* linkIdDictionary in linkIdsDictionaries) {
        NSString *idValue = linkIdDictionary[@"id"];
        if (idValue) {
            [linkIds addObject:idValue];
        }
    }
    return linkIds;
}

-(NSArray*) linkIdsDictionariesForLinkIds:(NSArray*)linkIds
{
    NSMutableArray *linkIdsDictionaries = [NSMutableArray arrayWithCapacity:linkIds.count];
    for (NSString* linkId in linkIds) {
        [linkIdsDictionaries addObject:@{@"id": linkId}];
    }
    return linkIdsDictionaries;
}

-(NSDictionary*) requestJSONWithLinks:(NSArray*)links
                                 mode:(NSString*)mode
{
    NSDictionary *jsonDictionary = @{
                                     @"username" : self.username,
                                     @"auth"     : self.authCode,
                                     @"dev"      : @"amrc",
                                     @"mode"     : mode,
                                     @"links"    : links
                                     };
    return jsonDictionary;
}

-(NSDictionary*) requestJSONWithHistorySinceDate:(NSDate*)sinceDate
                                          offset:(NSInteger)offset
{
    NSString *utcString;
    if (sinceDate) {
        utcString = [NSString stringWithFormat:@"%.0f",[sinceDate timeIntervalSince1970]];
    } else {
        utcString = @"0";
    }
    
    NSDictionary *jsonDictionary = @{
                                     @"username" : self.username,
                                     @"auth"     : self.authCode,
                                     @"dev"      : @"amrc",
                                     @"mode"     : @"history",
                                     @"time"    : utcString,
                                     @"offset" : [NSString stringWithFormat:@"%d",offset]
                                     };
    return jsonDictionary;
}


-(NSError*) errorWithDescription:(NSString*)desc
{
    NSParameterAssert([desc isKindOfClass:[NSString class]]);
    NSDictionary* userInfo = @{NSLocalizedDescriptionKey:desc};
    NSError* er = [NSError errorWithDomain:@"AFSynccitAPIClient" code:-999 userInfo:userInfo];
    return er;
}

#pragma mark Update timer

-(void) updateTimerSchedueling
{
    [self unscheduleUpdateTimer];
    if (_isReachable && [self isEnabled]) {
        [self rescheduleUpdateTimer];
    }
}

-(void) fireTimer
{
    if (self.updateTimer != nil) {
        [self updateTimerFireMethod:self.updateTimer];
    }
}

static NSTimeInterval kUpdateTimerInterval = 60.;

-(void) rescheduleUpdateTimer
{
    [self unscheduleUpdateTimer];
    self.updateTimer = [NSTimer timerWithTimeInterval:kUpdateTimerInterval
                                               target:self
                                             selector:@selector(updateTimerFireMethod:)
                                             userInfo:nil
                                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
    [self updateTimerFireMethod:self.updateTimer];
}

-(void) unscheduleUpdateTimer
{
    if (self.updateTimer == nil) {
        return;
    }
    
    [self.updateTimer performSelectorOnMainThread:@selector(invalidate) withObject:nil waitUntilDone:NO];
    self.updateTimer = nil;
}

#pragma mark NSNotification

- (void) applicationDidBecomeActiveNotification
{
    [self updateTimerSchedueling];
}

- (void) applicationWillResignActiveNotification
{
    [self fireTimer];
    [self unscheduleUpdateTimer];
}

-(void) reachabilityDidChange:(NSNotification*)notification
{
    NSNumber *statusNumber = [notification.userInfo objectForKey:AFNetworkingReachabilityNotificationStatusItem];
    NSInteger reachabilityStatus = [statusNumber integerValue];
    _isReachable =
    reachabilityStatus == AFNetworkReachabilityStatusReachableViaWiFi ||
    reachabilityStatus == AFNetworkReachabilityStatusReachableViaWWAN;
    [self updateTimerSchedueling];
}


@end
