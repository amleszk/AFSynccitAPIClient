
#import "AFSynccitAPIClient.h"
#import "AFJSONRequestOperation.h"

NSString * const kAFRSynccitAPIBaseURLString = @"http://api.synccit.com/api.php";

@interface AFSynccitAPIClient ()
@property NSMutableArray *linkIds;
@property NSTimer *updateTimer;
@property AFHTTPRequestOperation* updateOperation;
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
    
    
    self.linkIds = [NSMutableArray array];
    [self registerHTTPOperationClass:[AFHTTPRequestOperation class]];
    [self setDefaultHeader:@"Accept" value:@"application/json"];
    
    return self;
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) updateTimerFireMethod:(NSTimer*)timer
{
    if (self.linkIds.count == 0 || self.updateOperation != nil) {
        return;
    }
    
    NSArray *linkIdsSynccing = [self.linkIds copy];
    [self.linkIds removeAllObjects];
    
    NSDictionary *jsonDictionary = [self requestJSONWithLinks:linkIdsSynccing mode:@"update"];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSDictionary* parameters = @{@"type": @"json", @"data" : jsonString};
    
    void (^finally)(void) = ^{
        self.updateOperation = nil;
    };
    
    void (^success)(AFHTTPRequestOperation *operation, NSData* responseObject) =
    ^(AFHTTPRequestOperation *operation, NSData* responseObject)
    {
        finally();
        
        NSError *error;
        NSDictionary *jsonDictionary = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:&error];
        if (error) {
            DLog(@"synccit API update returned error %@", error);
            return;
        }
        
        if(![jsonDictionary isKindOfClass:[NSDictionary class]]){
            DLog(@"synccit API update returned non json");
            return;
        }
        
        if (jsonDictionary[@"error"] != nil) {
            DLog(@"synccit API update returned error %@", jsonDictionary[@"error"]);
            return;
        }
    };
    
    void (^failure)(AFHTTPRequestOperation *_operation, NSError *error) = ^(AFHTTPRequestOperation *_operation, NSError *error)
    {
        //retry on HTTP failure
        [self.linkIds addObjectsFromArray:linkIdsSynccing];
        
        finally();
        DLog(@"synccit API update failed %@", error);
    };
    
    
	NSURLRequest *request = [self requestWithMethod:@"POST" path:@"" parameters:parameters];
	self.updateOperation = [self HTTPRequestOperationWithRequest:request success:success failure:failure];
    [self enqueueHTTPRequestOperation:self.updateOperation];
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
    
    [self.linkIds addObject:@{@"id": linkId}];
}

-(void) setUsername:(NSString*)username authCode:(NSString*)authCode
{
    self.username = username;
    self.authCode = authCode;
    
    [self unscheduleUpdateTimer];
    
    if (self.username && self.authCode) {
        [self rescheduleUpdateTimer];
    }
}

-(void) statusForLinkIds:(NSArray*)linkIds
                 success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                 failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    if (self.username == nil || self.authCode == nil) {
        failure(nil, [self errorWithDescription:@"not logged in"]);
    }
    
    
    NSDictionary *jsonDictionary = [self requestJSONWithLinks:[self linkIdsDictionariesForLinkIds:linkIds] mode:@"read"];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDictionary options:0 error:&error];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSDictionary* parameters = @{@"type": @"json", @"data" : jsonString};
    
    
    void (^successWrapper)(AFHTTPRequestOperation *_operation, NSData* _responseObject) =
    ^(AFHTTPRequestOperation *_operation, NSData* _responseObject)
    {
        NSError *error;
        id json = [NSJSONSerialization JSONObjectWithData:_responseObject options:0 error:&error];
        if (error) {
            DLog(@"synccit API malformed response %@", [[NSString alloc] initWithData:_responseObject encoding:NSUTF8StringEncoding]);
            if(failure) failure(_operation,[self errorWithDescription:@"Malformed response"]);
            return;
        }
        
        if([json isKindOfClass:[NSDictionary class]] && json[@"error"] != nil ){
            NSString *error = [NSString stringWithFormat:@"Synccit returned error: %@",json[@"error"]];
            if(failure) failure(_operation,[self errorWithDescription:error]);
            return;
        }
        
        if(![json isKindOfClass:[NSArray class]]){
            if(failure) failure(_operation,[self errorWithDescription:@"Malformed response"]);
            return;
        }
        
        if(success) success(_operation,[self linkIdsArrayDictionary:json]);
    };
    
    void (^failureWrapper)(AFHTTPRequestOperation *_operation, NSError *_error) = ^(AFHTTPRequestOperation *_operation, NSError *_error)
    {
        if(failure) failure(_operation,_error);
        DLog(@"synccit API update failed %@", error);
    };
    
	NSURLRequest *request = [self requestWithMethod:@"POST" path:@"" parameters:parameters];
	AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:successWrapper failure:failureWrapper];
    [self enqueueHTTPRequestOperation:operation];
}

-(void) statusForRedditAPIResponse:(NSDictionary*)redditAPIResponse
                           visited:(void (^)(NSArray *visitedLinkData))visited;

{
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

#pragma mark Helpers

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

-(NSDictionary*) requestJSONWithLinks:(NSArray*)links mode:(NSString*)mode
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


-(NSError*) errorWithDescription:(NSString*)desc
{
    NSParameterAssert([desc isKindOfClass:[NSString class]]);
    NSDictionary* userInfo = @{NSLocalizedDescriptionKey:desc};
    NSError* er = [NSError errorWithDomain:@"AFSynccitAPIClient" code:-999 userInfo:userInfo];
    return er;
}

#pragma mark Update timer

-(void) rescheduleUpdateTimer
{
    [self unscheduleUpdateTimer];
    self.updateTimer = [NSTimer timerWithTimeInterval:10.
                                               target:self
                                             selector:@selector(updateTimerFireMethod:)
                                             userInfo:nil
                                              repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
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
    [self rescheduleUpdateTimer];
}

- (void) applicationWillResignActiveNotification
{
    [self updateTimerFireMethod:self.updateTimer];
    [self unscheduleUpdateTimer];
}

@end
