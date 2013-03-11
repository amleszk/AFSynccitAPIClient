
#import "AFHTTPClient.h"

@interface AFSynccitAPIClient : AFHTTPClient

@property NSString *username;
@property NSString *authCode;


+ (AFSynccitAPIClient *)sharedClient;

-(void) addLinkId:(NSString*)linkId;
-(void) setUsername:(NSString*)username authCode:(NSString*)authCode;

-(void) statusForLinkIds:(NSArray*)linkIds
                 success:(void (^)(AFHTTPRequestOperation *operation, NSArray *linkStatuses))success
                 failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure;

-(void) statusForRedditAPIResponse:(NSDictionary*)redditAPIResponse
                           visited:(void (^)(NSArray *visitedLinkData))visited;


@end
