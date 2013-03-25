
#import "AFHTTPClient.h"

@interface AFSynccitAPIClient : AFHTTPClient

@property NSString *username;
@property NSString *authCode;
@property NSDate *lastDownloadSyncDate;

+ (AFSynccitAPIClient *)sharedClient;
-(BOOL) isEnabled;
-(void) setUsername:(NSString*)username authCode:(NSString*)authCode;
-(void) updateTimerSchedueling;
- (void) completeDownloadOperation;

#pragma mark Upload

-(void) addLinkId:(NSString*)linkId;

-(void) addLinkId:(NSString*)linkId
    commentsCount:(NSString*)commentsCount
         linkRead:(BOOL)linkRead
     commentsRead:(BOOL)commentsRead;

#pragma mark Download

//Synccit status for an array of ids @[@"12423",@"12423",@"12423"]
-(void) statusForLinkIds:(NSArray*)linkIds
                 success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                 failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure;

//Synccit status for a json payload e.g. http://www.reddit.com/r/iphone.json
-(void) statusForRedditAPIResponse:(NSDictionary*)redditAPIResponse
                           visited:(void (^)(NSArray *visitedLinkData))visited;

-(AFHTTPRequestOperation*) linksSinceDate:(NSDate*)date
                                   offset:(NSInteger)offset
                                  success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                                  failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure;

extern NSString *const AFSynccitAPIClientNotificationNewLinks;
extern NSString *const AFSynccitAPIClientLinksDownloadedUserInfoKey;


@end
