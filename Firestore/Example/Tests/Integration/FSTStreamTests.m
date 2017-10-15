/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#import <FirebaseCommunity/FIRLogger.h>
#import <Firestore/FIRFirestoreSettings.h>

#import "Auth/FSTEmptyCredentialsProvider.h"
#import "Core/FSTDatabaseInfo.h"
#import "FIRTestDispatchQueue.h"
#import "FSTHelpers.h"
#import "FSTIntegrationTestCase.h"
#import "Model/FSTDatabaseID.h"
#import "Remote/FSTDatastore.h"

/** Expose otherwise private methods for testing. */
@interface FSTStream (Testing)
- (void)writesFinishedWithError:(NSError *_Nullable)error;
@end

@interface FSTStreamStatusDelegate : NSObject <FSTWatchStreamDelegate, FSTWriteStreamDelegate>

- (instancetype)init;
- (void)waitForHandshake;
- (void)waitForOpen;
- (void)waitForClose;
- (void)waitForResponse;

@property(nonatomic, readonly) NSMutableArray<NSString *> *states;

@end

@implementation FSTStreamStatusDelegate

dispatch_semaphore_t _openSemaphore;
dispatch_semaphore_t _closeSemaphore;
dispatch_semaphore_t _watchChangeSemaphore;
dispatch_semaphore_t _handshakeSemaphore;
dispatch_semaphore_t _responseReceivedSemaphore;

- (instancetype)init {
  if (self = [super init]) {
    _openSemaphore = dispatch_semaphore_create(0);
    _closeSemaphore = dispatch_semaphore_create(0);
    _watchChangeSemaphore = dispatch_semaphore_create(0);
    _handshakeSemaphore = dispatch_semaphore_create(0);
    _responseReceivedSemaphore = dispatch_semaphore_create(0);
    _states = [NSMutableArray new];
  }

  return self;
}

- (void)streamDidReceiveChange:(FSTWatchChange *)change
               snapshotVersion:(FSTSnapshotVersion *)snapshotVersion {
  [_states addObject:@"didReceiveChange"];
  dispatch_semaphore_signal(_watchChangeSemaphore);
}

- (void)streamDidOpen {
  [_states addObject:@"didOpen"];
  dispatch_semaphore_signal(_openSemaphore);
}

- (void)streamDidClose:(NSError *_Nullable)error {
  [_states addObject:@"didClose"];
  dispatch_semaphore_signal(_closeSemaphore);
}

- (void)streamDidCompleteHandshake {
  [_states addObject:@"didCompleteHandshake"];
  dispatch_semaphore_signal(_handshakeSemaphore);
}

- (void)streamDidReceiveResponseWithVersion:(FSTSnapshotVersion *)commitVersion
                            mutationResults:(NSArray<FSTMutationResult *> *)results {
  [_states addObject:@"didReceiveResponse"];
  dispatch_semaphore_signal(_responseReceivedSemaphore);
}

- (void)waitForHandshake {
  dispatch_semaphore_wait(_handshakeSemaphore, DISPATCH_TIME_FOREVER);
}

- (void)waitForOpen {
  dispatch_semaphore_wait(_openSemaphore, DISPATCH_TIME_FOREVER);
}

- (void)waitForClose {
  dispatch_semaphore_wait(_closeSemaphore, DISPATCH_TIME_FOREVER);
}

- (void)waitForResponse {
  dispatch_semaphore_wait(_responseReceivedSemaphore, DISPATCH_TIME_FOREVER);
}

@end

@interface FSTStreamTests : XCTestCase

@end

@implementation FSTStreamTests {
  dispatch_queue_t _testQueue;
  FSTDatabaseInfo *_databaseInfo;
  FSTTestDispatchQueue *_workerDispatchQueue;
  FSTEmptyCredentialsProvider *_credentials;
  FSTStreamStatusDelegate *_delegate;

  /** Single mutation to send to the write stream. */
  NSArray<FSTMutation *> *_mutations;
}

- (void)setUp {
  [super setUp];

  FIRSetLoggerLevel(FIRLoggerLevelDebug);

  NSString *projectID = [FSTIntegrationTestCase projectID];
  FIRFirestoreSettings *settings = [FSTIntegrationTestCase settings];
  FSTDatabaseID *databaseID =
      [FSTDatabaseID databaseIDWithProject:projectID database:kDefaultDatabaseID];

  _databaseInfo = [FSTDatabaseInfo databaseInfoWithDatabaseID:databaseID
                                               persistenceKey:@"test-key"
                                                         host:settings.host
                                                   sslEnabled:settings.sslEnabled];

  _testQueue =
      dispatch_queue_create("com.google.firestore.FSTStreamTestWorkerQueue", DISPATCH_QUEUE_SERIAL);
  _workerDispatchQueue = [[FSTTestDispatchQueue alloc] initWithQueue:_testQueue];
  _credentials = [[FSTEmptyCredentialsProvider alloc] init];

  _mutations = @[ FSTTestSetMutation(@"foo/bar", @{}) ];

  _delegate = [FSTStreamStatusDelegate new];
}

- (void)tearDown {
  [super tearDown];
}

- (FSTWriteStream *)setUpAndStartWriteStream {
  FSTDatastore *datastore = [[FSTDatastore alloc] initWithDatabaseInfo:_databaseInfo
                                                   workerDispatchQueue:_workerDispatchQueue
                                                           credentials:_credentials];
  FSTWriteStream *stream = [datastore createWriteStream];

  dispatch_sync(_testQueue, ^{
    [stream start:_delegate];
  });

  [_delegate waitForOpen];

  return stream;
}

- (FSTWatchStream *)setUpAndStartWatchStream {
  FSTDatastore *datastore = [[FSTDatastore alloc] initWithDatabaseInfo:_databaseInfo
                                                   workerDispatchQueue:_workerDispatchQueue
                                                           credentials:_credentials];
  FSTWatchStream *stream = [datastore createWatchStream];

  dispatch_sync(_testQueue, ^{
    [stream start:_delegate];
  });

  [_delegate waitForOpen];

  return stream;
}

- (void)verifyDelegate:(NSArray<NSString *> *)expectedStates {
  // Drain queue
  dispatch_sync(_testQueue, ^{
                });

  XCTAssertEqualObjects(_delegate.states, expectedStates);
}

/** Verifies that the stream does not issue an onClose callback after a call to stop(). */
- (void)testWatchStreamStopBeforeHandshake {
  FSTWatchStream *watchStream = [self setUpAndStartWatchStream];

  // Stop must not call watchStreamDidClose because the full implementation of the delegate could
  // attempt to restart the stream in the event it had pending watches.
  dispatch_sync(_testQueue, ^{
    [watchStream stop];
  });

  // Simulate a final callback from GRPC
  [watchStream writesFinishedWithError:nil];

  [self verifyDelegate:@[ @"didOpen" ]];
}

/** Verifies that the stream does not issue an onClose callback after a call to stop(). */
- (void)testWriteStreamStopBeforeHandshake {
  FSTWriteStream *writeStream = [self setUpAndStartWriteStream];

  // Don't start the handshake

  // Stop must not call watchStreamStreamDidClose because the full implementation of the delegate
  // could attempt to restart the stream in the event it had pending writes.
  dispatch_sync(_testQueue, ^{
    [writeStream stop];
  });

  // Drain queue
  dispatch_sync(_testQueue, ^{
                });
  [self verifyDelegate:@[ @"didOpen" ]];
}

- (void)testWriteStreamStopAfterHandshake {
  FSTWriteStream *writeStream = [self setUpAndStartWriteStream];

  // Writing before the handshake should throw
  dispatch_sync(_testQueue, ^{
    XCTAssertThrows([writeStream writeMutations:_mutations]);
  });

  // Handshake should always be called
  dispatch_sync(_testQueue, ^{
    [writeStream writeHandshake];
  });
  [_delegate waitForHandshake];
  XCTAssertNotNil([writeStream lastStreamToken]);

  // Now writes should succeed
  dispatch_sync(_testQueue, ^{
    [writeStream writeMutations:_mutations];
  });
  [_delegate waitForResponse];

  dispatch_sync(_testQueue, ^{
    [writeStream stop];
  });

  [self verifyDelegate:@[ @"didOpen", @"didCompleteHandshake", @"didReceiveResponse" ]];
}

- (void)testStreamClosesWhenIdle {
  FSTWriteStream *writeStream = [self setUpAndStartWriteStream];

  dispatch_sync(_testQueue, ^{
    [writeStream writeHandshake];
  });

  [_delegate waitForHandshake];

  [writeStream markIdle];

  [_delegate waitForClose];
  dispatch_sync(_testQueue, ^{
    XCTAssertFalse([writeStream isOpen]);
  });

  [self verifyDelegate:@[ @"didOpen", @"didCompleteHandshake", @"didClose" ]];
}

- (void)testStreamCancelsIdleOnWrite {
  FSTWriteStream *writeStream = [self setUpAndStartWriteStream];

  dispatch_sync(_testQueue, ^{
    [writeStream writeHandshake];
  });

  [_delegate waitForHandshake];

  [writeStream markIdle];

  dispatch_sync(_testQueue, ^{
    XCTAssertThrows(^() {
      [writeStream writeMutations:_mutations];
    });
  });

  [_workerDispatchQueue waitForDelayedExecution];

  dispatch_sync(_testQueue, ^{
    XCTAssertFalse([writeStream isOpen]);
  });

  dispatch_sync(_testQueue, ^{
    [writeStream stop];
  });

  [self verifyDelegate:@[ @"didOpen", @"didCompleteHandshake", @"didReceiveResponse" ]];
}

@end
