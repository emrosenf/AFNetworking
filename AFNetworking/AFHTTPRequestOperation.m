// AFHTTPOperation.m
//
// Copyright (c) 2011 Gowalla (http://gowalla.com/)
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

#define AF_RESUMABLE_PLIST_PATH [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"AFResumableTransfers.plist"]

#import "AFHTTPRequestOperation.h"

static NSString * AFStringFromIndexSet(NSIndexSet *indexSet) {
    NSMutableString *string = [NSMutableString string];

    NSRange range = NSMakeRange([indexSet firstIndex], 1);
    while (range.location != NSNotFound) {
        NSUInteger nextIndex = [indexSet indexGreaterThanIndex:range.location];
        while (nextIndex == range.location + range.length) {
            range.length++;
            nextIndex = [indexSet indexGreaterThanIndex:nextIndex];
        }

        if (string.length) {
            [string appendString:@","];
        }

        if (range.length == 1) {
            [string appendFormat:@"%u", range.location];
        } else {
            NSUInteger firstIndex = range.location;
            NSUInteger lastIndex = firstIndex + range.length - 1;
            [string appendFormat:@"%u-%u", firstIndex, lastIndex];
        }

        range.location = nextIndex;
        range.length = 1;
    }

    return string;
}

#pragma mark -

@interface AFHTTPRequestOperation ()
@property (readwrite, nonatomic, retain) NSError *HTTPError;
@end

@implementation AFHTTPRequestOperation
@synthesize acceptableStatusCodes = _acceptableStatusCodes;
@synthesize acceptableContentTypes = _acceptableContentTypes;
@synthesize HTTPError = _HTTPError;
@synthesize successCallbackQueue = _successCallbackQueue;
@synthesize failureCallbackQueue = _failureCallbackQueue;
@synthesize temporaryFilePath = _temporaryFilePath;
@synthesize resumable = _resumable;

- (id)initWithRequest:(NSURLRequest *)request {
    self = [super initWithRequest:request];
    if (!self) {
        return nil;
    }
    
    self.acceptableStatusCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
    
    return self;
}

- (void)dealloc {
    [_acceptableStatusCodes release];
    [_acceptableContentTypes release];
    [_HTTPError release];
    
    if (_successCallbackQueue) { 
        dispatch_release(_successCallbackQueue);
        _successCallbackQueue = NULL;
    }
    
    if (_failureCallbackQueue) { 
        dispatch_release(_failureCallbackQueue); 
        _failureCallbackQueue = NULL;
    }
    
    [super dealloc];
}

- (void)setTemporaryFilePath:(NSString *)temporaryFilePath {
    if (temporaryFilePath == _temporaryFilePath) return;
    if (self.outputStream) {
        [self.outputStream close];
    }
    _temporaryFilePath = temporaryFilePath;
    startingFileSize = 0;
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSDictionary *dict = [fm attributesOfItemAtPath:temporaryFilePath error:NULL];
    [fm release];
    if (dict) {
        startingFileSize = [[dict objectForKey:NSFileSize] unsignedLongLongValue];
    }
    BOOL append = NO;
    if (startingFileSize > 0) {
        append = YES;
        NSMutableURLRequest *request = [[self.request mutableCopy] autorelease];
        NSString *range = @"bytes=";
        range = [range stringByAppendingFormat:@"%llu", startingFileSize];
        range = [range stringByAppendingString:@"-"];
        [request setValue:range forHTTPHeaderField:@"Range"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:AF_RESUMABLE_PLIST_PATH];
        NSString *ETag = [plist objectForKey:[NSString stringWithFormat:@"%lu", [request.URL hash]]];
                         
        if (ETag) {
            [request setValue:ETag forHTTPHeaderField:@"ETag"];
        }
        [_request release]; _request = nil;
        _request = [request retain];
    }
    self.outputStream = [NSOutputStream outputStreamToFileAtPath:_temporaryFilePath append:append];

}

- (void)connection:(NSURLConnection *) connection 
didReceiveResponse:(NSURLResponse *)response 
{
    [super connection:connection didReceiveResponse:response];
    if (_temporaryFilePath) {
        NSDictionary *dict = [(NSHTTPURLResponse*)response allHeaderFields];
        NSString *eTag = [dict objectForKey:@"ETag"];
        if (eTag) {
            NSUInteger hash = [[response URL] hash];
            NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:AF_RESUMABLE_PLIST_PATH];
            if (!plist) plist = [NSMutableDictionary dictionary];
            [plist setObject:eTag forKey:[NSString stringWithFormat:@"%lu", hash]];
            [plist writeToFile:AF_RESUMABLE_PLIST_PATH atomically:YES];
        }
    }
    
}

- (NSHTTPURLResponse *)response {
    return (NSHTTPURLResponse *)[super response];
}

- (NSError *)error {
    if (self.response && !self.HTTPError) {
        if (![self hasAcceptableStatusCode]) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Expected status code in (%@), got %d", nil), AFStringFromIndexSet(self.acceptableStatusCodes), [self.response statusCode]] forKey:NSLocalizedDescriptionKey];
            [userInfo setValue:[self.request URL] forKey:NSURLErrorFailingURLErrorKey];
            
            self.HTTPError = [[[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:NSURLErrorBadServerResponse userInfo:userInfo] autorelease];
        } else if ([self.responseData length] > 0 && ![self hasAcceptableContentType]) { // Don't invalidate content type if there is no content
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Expected content type %@, got %@", nil), self.acceptableContentTypes, [self.response MIMEType]] forKey:NSLocalizedDescriptionKey];
            [userInfo setValue:[self.request URL] forKey:NSURLErrorFailingURLErrorKey];
            
            self.HTTPError = [[[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:userInfo] autorelease];
        }
    }
    
    if (self.HTTPError) {
        return self.HTTPError;
    } else {
        return [super error];
    }
}

- (BOOL)hasAcceptableStatusCode {
    return !self.acceptableStatusCodes || [self.acceptableStatusCodes containsIndex:[self.response statusCode]];
}

- (BOOL)hasAcceptableContentType {
    return !self.acceptableContentTypes || [self.acceptableContentTypes containsObject:[self.response MIMEType]];
}

- (void)setSuccessCallbackQueue:(dispatch_queue_t)successCallbackQueue {
    if (successCallbackQueue != _successCallbackQueue) {
        if (_successCallbackQueue) {
            dispatch_release(_successCallbackQueue);
        }
     
        if (successCallbackQueue) {
            dispatch_retain(successCallbackQueue);
            _successCallbackQueue = successCallbackQueue;
        }
    }    
}

- (void)setFailureCallbackQueue:(dispatch_queue_t)failureCallbackQueue {
    if (failureCallbackQueue != _failureCallbackQueue) {
        if (_failureCallbackQueue) {
            dispatch_release(_failureCallbackQueue);
        }
        
        if (failureCallbackQueue) {
            dispatch_retain(failureCallbackQueue);
            _failureCallbackQueue = failureCallbackQueue;
        }
    }    
}

- (void)setCompletionBlockWithSuccess:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    self.completionBlock = ^ {
        if ([self isCancelled]) {
            return;
        }
        
        if (self.error) {
            if (failure) {
                dispatch_async(self.failureCallbackQueue ? self.failureCallbackQueue : dispatch_get_main_queue(), ^{
                    failure(self, self.error);
                });
            }
        } else {
            if (success) {
                dispatch_async(self.successCallbackQueue ? self.successCallbackQueue : dispatch_get_main_queue(), ^{
                    success(self, self.responseData);
                });
            }
        }
    };
}

#pragma mark - AFHTTPClientOperation

+ (BOOL)canProcessRequest:(NSURLRequest *)request {
    return YES;
}

@end
