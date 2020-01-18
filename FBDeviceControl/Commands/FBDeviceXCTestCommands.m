/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <FBControlCore/FBControlCore.h>

#import <XCTestBootstrap/XCTestBootstrap.h>

#import "FBAMDevice+Private.h"
#import "FBAMDevice.h"
#import "FBDevice+Private.h"
#import "FBDevice.h"
#import "FBDeviceControlError.h"
#import "FBDeviceXCTestCommands.h"
#import "FBAMDServiceConnection.h"

static inline id readFromDict(NSDictionary *dict, NSString *key, Class klass)
{
  id val = dict[key];
  NSCAssert(val, @"%@ is not present in dict", key);
  val = [val isKindOfClass:klass] ? val : nil;
  NSCAssert(val, @"%@ is not a %@", key, klass);
  return val;
}

static inline NSNumber *readNumberFromDict(NSDictionary *dict, NSString *key)
{
  return readFromDict(dict, key, NSNumber.class);
}

static inline double readDoubleFromDict(NSDictionary *dict, NSString *key)
{
  NSNumber *number = readNumberFromDict(dict, key);
  return [number doubleValue];
}

static inline NSString *readStringFromDict(NSDictionary *dict, NSString *key)
{
  return readFromDict(dict, key, NSString.class);
}

static inline NSArray *readArrayFromDict(NSDictionary *dict, NSString *key)
{
  return readFromDict(dict, key, NSArray.class);
}

static inline NSArray *unwrapValues(NSDictionary<NSString *, NSObject *> *wrappedObject)
{
  @try {
    return readFromDict(wrappedObject, @"_values", NSArray.class);
  }
  @catch (id e) {
    return nil;
  }
}

static inline id unwrapValue(NSDictionary<NSString *, NSObject *> *wrappedObject)
{
  @try {
    return readFromDict(wrappedObject, @"_value", NSObject.class);
  }
  @catch (id e) {
    return nil;
  }
}

static inline NSDate *dateFromString(NSString *date)
{
  // @lint-ignore FBOBJCDISCOURAGEDFUNCTION
  NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
  [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSZ"];
  return [dateFormatter dateFromString:date];
}

@interface FBDeviceXCTestCommands ()

@property (nonatomic, weak, readonly) FBDevice *device;
@property (nonatomic, copy, readonly) NSString *workingDirectory;
@property (nonatomic, strong, readonly) FBProcessFetcher *processFetcher;
@property (nonatomic, strong, nullable, readwrite) id<FBiOSTargetContinuation> operation;

@end

@implementation FBDeviceXCTestCommands

#pragma mark Initializers

+ (instancetype)commandsWithTarget:(FBDevice *)target
{
  return [[self alloc] initWithDevice:target workingDirectory:NSTemporaryDirectory()];
}

- (instancetype)initWithDevice:(FBDevice *)device workingDirectory:(NSString *)workingDirectory
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _device = device;
  _workingDirectory = workingDirectory;
  _processFetcher = [FBProcessFetcher new];

  return self;
}

#pragma mark Public: Legacy XCTest Result

+ (void)reportTestMethod:(NSDictionary<NSString *, NSObject *> *)testMethod testBundleName:(NSString *)testBundleName testClassName:(NSString *)testClassName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testMethod, @"testMethod is nil");
  NSAssert([testMethod isKindOfClass:NSDictionary.class], @"testMethod not a NSDictionary");

  NSString *testStatus = readStringFromDict(testMethod, @"TestStatus");
  NSString *testMethodName = readStringFromDict(testMethod, @"TestIdentifier");
  NSNumber *duration = readNumberFromDict(testMethod, @"Duration");

  FBTestReportStatus status = FBTestReportStatusUnknown;
  if ([testStatus isEqualToString:@"Success"]) {
    status = FBTestReportStatusPassed;
  }
  if ([testStatus isEqualToString:@"Failure"]) {
    status = FBTestReportStatusFailed;
  }

  NSArray *activitySummaries = readArrayFromDict(testMethod, @"ActivitySummaries");
  NSMutableArray *logs = [self buildTestLogLegacy:activitySummaries
                                   testBundleName:testBundleName
                                    testClassName:testClassName
                                   testMethodName:testMethodName
                                       testPassed:status == FBTestReportStatusPassed
                                         duration:[duration doubleValue]];

  [reporter testManagerMediator:nil testCaseDidStartForTestClass:testClassName method:testMethodName];
  if (status == FBTestReportStatusFailed) {
    NSArray *failureSummaries = readArrayFromDict(testMethod, @"FailureSummaries");
    [reporter testManagerMediator:nil testCaseDidFailForTestClass:testClassName method:testMethodName withMessage:[self buildErrorMessageLegacy:failureSummaries] file:nil line:0];
  }

  if ([reporter respondsToSelector:@selector(testManagerMediator:testCaseDidFinishForTestClass:method:withStatus:duration:logs:)]) {
    [reporter testManagerMediator:nil testCaseDidFinishForTestClass:testClassName method:testMethodName withStatus:status duration:[duration doubleValue] logs:[logs copy]];
  }
  else {
    [reporter testManagerMediator:nil testCaseDidFinishForTestClass:testClassName method:testMethodName withStatus:status duration:[duration doubleValue]];
  }
}

+ (void)reportTestMethods:(NSArray<NSDictionary *> *)testMethods testBundleName:(NSString *)testBundleName testClassName:(NSString *)testClassName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testMethods, @"testMethods is nil");
  NSAssert([testMethods isKindOfClass:NSArray.class], @"testMethods not a NSArray");

  for (NSDictionary *testMethod in testMethods) {
    [self reportTestMethod:testMethod testBundleName:testBundleName testClassName:testClassName reporter:reporter];
  }
}

+ (void)reportTestClass:(NSDictionary<NSString *, NSObject *> *)testClass testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testClass, @"selectedTest is nil");
  NSAssert([testClass isKindOfClass:NSDictionary.class], @"testClass not a NSDictionary");

  NSString *testClassName = readStringFromDict(testClass, @"TestIdentifier");
  NSArray<NSDictionary *> *testMethods = (NSArray<NSDictionary *> *)testClass[@"Subtests"];
  [self reportTestMethods:testMethods testBundleName:testBundleName testClassName:testClassName reporter:reporter];
}

+ (void)reportTestClasses:(NSArray<NSDictionary *> *)testClasses testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testClasses, @"selectedTest is nil");
  NSAssert([testClasses isKindOfClass:NSArray.class], @"testClasses not a NSArray");

  for (NSDictionary *testClass in testClasses) {
    [self reportTestClass:testClass testBundleName:testBundleName reporter:reporter];
  }
}

+ (void)reportTestTargetXctest:(NSDictionary<NSString *, NSObject *> *)testTargetXctest testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testTargetXctest, @"selectedTest is nil");
  NSAssert([testTargetXctest isKindOfClass:NSDictionary.class], @"testTargetXctest not a NSDictionary");

  NSArray *testClasses = (NSArray *)testTargetXctest[@"Subtests"];
  [self reportTestClasses:testClasses testBundleName:testBundleName reporter:reporter];
}

+ (void)reportTestTargetXctests:(NSArray<NSDictionary *> *)testTargetXctests testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(testTargetXctests, @"testTargetXctests is nil");
  NSAssert([testTargetXctests isKindOfClass:NSArray.class], @"testTargetXctests not a NSArray");

  for (NSDictionary *testTargetXctest in testTargetXctests) {
    [self reportTestTargetXctest:testTargetXctest testBundleName:testBundleName reporter:reporter];
  }
}

+ (void)reportSelectedTest:(NSDictionary<NSString *, NSObject *> *)selectedTest testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(selectedTest, @"selectedTest is nil");
  NSAssert([selectedTest isKindOfClass:NSDictionary.class], @"selectedTest not a NSDictionary");

  NSArray<NSDictionary *> *testTargetXctests = (NSArray<NSDictionary *> *)selectedTest[@"Subtests"];
  [self reportTestTargetXctests:testTargetXctests testBundleName:testBundleName reporter:reporter];
}

+ (void)reportSelectedTests:(NSArray<NSDictionary *> *)selectedTests testBundleName:(NSString *)testBundleName reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(selectedTests, @"selectedTests is nil");
  NSAssert([selectedTests isKindOfClass:NSArray.class], @"selectedTests not a NSArray");

  for (NSDictionary *selectedTest in selectedTests) {
    [self reportSelectedTest:selectedTest testBundleName:testBundleName reporter:reporter];
  }
}

+ (void)reportTargetTest:(NSDictionary<NSString *, NSObject *> *)targetTest reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(targetTest, @"targetTest is nil");
  NSAssert([targetTest isKindOfClass:NSDictionary.class], @"targetTest not a NSDictionary");
  NSString *testBundleName = readStringFromDict(targetTest, @"TestName");

  NSArray<NSDictionary *> *selectedTests = (NSArray<NSDictionary *> *)targetTest[@"Tests"];
  [self reportSelectedTests:selectedTests testBundleName:testBundleName reporter:reporter];
}

+ (void)reportTargetTests:(NSArray<NSDictionary *> *)targetTests reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert(targetTests, @"targetTests is nil");
  NSAssert([targetTests isKindOfClass:NSArray.class], @"targetTests not a NSArray");

  for (NSDictionary<NSString *, NSObject *> *targetTest in targetTests) {
    [self reportTargetTest:targetTest reporter:reporter];
  }
}

+ (void)reportResults:(NSDictionary<NSString *, NSArray *> *)results reporter:(id<FBTestManagerTestReporter>)reporter
{
  NSAssert([results isKindOfClass:NSDictionary.class], @"Test results not a NSDictionary");
  NSArray<NSDictionary *> *testTargets = results[@"TestableSummaries"];

  [self reportTargetTests:testTargets reporter:reporter];
}

#pragma mark Public: Xcode 11 XCTest Result

+ (void)reportTestMethod:(NSDictionary<NSString *, NSDictionary *> *)testMethod
          testBundleName:(NSString *)testBundleName
           testClassName:(NSString *)testClassName
                reporter:(id<FBTestManagerTestReporter>)reporter
                   queue:(dispatch_queue_t)queue
        resultBundlePath:(NSString *)resultBundlePath
                  logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testMethod, @"testMethod is nil");
  NSAssert([testMethod isKindOfClass:NSDictionary.class], @"testMethod not a NSDictionary");

  NSString *testStatus = (NSString *)unwrapValue(testMethod[@"testStatus"]);
  NSString *testMethodName = (NSString *)unwrapValue(testMethod[@"identifier"]);
  NSNumber *duration = (NSNumber *)unwrapValue(testMethod[@"duration"]);

  FBTestReportStatus status = FBTestReportStatusUnknown;
  if ([testStatus isEqualToString:@"Success"]) {
    status = FBTestReportStatusPassed;
  }
  if ([testStatus isEqualToString:@"Failure"]) {
    status = FBTestReportStatusFailed;
  }

  [reporter testManagerMediator:nil testCaseDidStartForTestClass:testClassName method:testMethodName];

  NSDictionary<NSString *, NSDictionary *> *summaryRef = testMethod[@"summaryRef"];
  NSAssert(summaryRef, @"Summary reference is nil");
  NSAssert([summaryRef isKindOfClass:NSDictionary.class], @"Summary reference not a NSDictionary");
  NSString *summaryRefId = (NSString *)unwrapValue(summaryRef[@"id"]);
  if (summaryRefId != nil) {
    [[[FBXCTestResultToolOperation
      getJSONFrom:resultBundlePath forId:summaryRefId queue:queue logger:logger]
      onQueue:queue doOnResolved:^(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *actionTestSummary) {
        if (status == FBTestReportStatusFailed) {
          NSArray *failureSummaries = unwrapValues(actionTestSummary[@"failureSummaries"]);
          [reporter testManagerMediator:nil testCaseDidFailForTestClass:testClassName method:testMethodName withMessage:[self buildErrorMessage:failureSummaries] file:nil line:0];
        }

        NSArray<NSDictionary *> *activitySummaries = unwrapValues(actionTestSummary[@"activitySummaries"]);
        [self extractScreenshotsFromActivities:activitySummaries queue:queue resultBundlePath:resultBundlePath logger:logger];

        if ([reporter respondsToSelector:@selector(testManagerMediator:testCaseDidFinishForTestClass:method:withStatus:duration:logs:)]) {
          NSMutableArray *logs = [self buildTestLog:activitySummaries
                                     testBundleName:testBundleName
                                      testClassName:testClassName
                                     testMethodName:testMethodName
                                         testPassed:status == FBTestReportStatusPassed
                                           duration:[duration doubleValue]];
          [reporter testManagerMediator:nil testCaseDidFinishForTestClass:testClassName method:testMethodName withStatus:status duration:[duration doubleValue] logs:[logs copy]];
        }
        else {
          [reporter testManagerMediator:nil testCaseDidFinishForTestClass:testClassName method:testMethodName withStatus:status duration:[duration doubleValue]];
        }
      }] await:nil];
  }
}

+ (void)reportTestMethods:(NSArray<NSDictionary *> *)testMethods
           testBundleName:(NSString *)testBundleName
            testClassName:(NSString *)testClassName
                 reporter:(id<FBTestManagerTestReporter>)reporter
                    queue:(dispatch_queue_t)queue
         resultBundlePath:(NSString *)resultBundlePath
                   logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testMethods, @"testMethods is nil");
  NSAssert([testMethods isKindOfClass:NSArray.class], @"testMethods not a NSArray");

  for (NSDictionary *testMethod in testMethods) {
    [self reportTestMethod:testMethod testBundleName:testBundleName testClassName:testClassName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (void)reportTestClass:(NSDictionary<NSString *, NSDictionary *> *)testClass
         testBundleName:(NSString *)testBundleName
               reporter:(id<FBTestManagerTestReporter>)reporter
                  queue:(dispatch_queue_t)queue
       resultBundlePath:(NSString *)resultBundlePath
                 logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testClass, @"selectedTest is nil");
  NSAssert([testClass isKindOfClass:NSDictionary.class], @"testClass not a NSDictionary");

  NSString *testClassName = (NSString *)unwrapValue(testClass[@"identifier"]);
  NSArray<NSDictionary *> *testMethods = unwrapValues(testClass[@"subtests"]);
  if (testMethods != nil) {
    [self reportTestMethods:testMethods testBundleName:testBundleName testClassName:testClassName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
  else {
    [logger logFormat:@"Test failed for %@ and no test method results found", testClassName];
    [reporter testManagerMediator:nil testCaseDidFailForTestClass:testClassName method:@"" withMessage:@"" file:nil line:0];
  }
}

+ (void)reportTestClasses:(NSArray<NSDictionary *> *)testClasses
           testBundleName:(NSString *)testBundleName
                 reporter:(id<FBTestManagerTestReporter>)reporter
                    queue:(dispatch_queue_t)queue
         resultBundlePath:(NSString *)resultBundlePath
                   logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testClasses, @"selectedTest is nil");
  NSAssert([testClasses isKindOfClass:NSArray.class], @"testClasses not a NSArray");

  for (NSDictionary *testClass in testClasses) {
    [self reportTestClass:testClass testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (void)reportTestTargetXctest:(NSDictionary<NSString *, NSDictionary *> *)testTargetXctest
                testBundleName:(NSString *)testBundleName
                      reporter:(id<FBTestManagerTestReporter>)reporter
                         queue:(dispatch_queue_t)queue
              resultBundlePath:(NSString *)resultBundlePath
                        logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testTargetXctest, @"selectedTest is nil");
  NSAssert([testTargetXctest isKindOfClass:NSDictionary.class], @"testTargetXctest not a NSDictionary");

  NSArray *testClasses = unwrapValues(testTargetXctest[@"subtests"]);
  if (testClasses != nil) {
    [self reportTestClasses:testClasses testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
  else {
    [logger log:@"Test failed and no test class results found in the bundle"];
    [reporter testManagerMediator:nil testCaseDidFailForTestClass:@"" method:@"" withMessage:@"" file:nil line:0];
  }
}

+ (void)reportTestTargetXctests:(NSArray<NSDictionary *> *)testTargetXctests
                 testBundleName:(NSString *)testBundleName
                       reporter:(id<FBTestManagerTestReporter>)reporter
                          queue:(dispatch_queue_t)queue
               resultBundlePath:(NSString *)resultBundlePath
                         logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(testTargetXctests, @"testTargetXctests is nil");
  NSAssert([testTargetXctests isKindOfClass:NSArray.class], @"testTargetXctests not a NSArray");

  for (NSDictionary *testTargetXctest in testTargetXctests) {
    [self reportTestTargetXctest:testTargetXctest testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (void)reportSelectedTest:(NSDictionary<NSString *, NSDictionary *> *)selectedTest
            testBundleName:(NSString *)testBundleName
                  reporter:(id<FBTestManagerTestReporter>)reporter
                     queue:(dispatch_queue_t)queue
          resultBundlePath:(NSString *)resultBundlePath
                    logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(selectedTest, @"selectedTest is nil");
  NSAssert([selectedTest isKindOfClass:NSDictionary.class], @"selectedTest not a NSDictionary");

  NSArray<NSDictionary *> *testTargetXctests = unwrapValues(selectedTest[@"subtests"]);
  if (testTargetXctests != nil) {
    [self reportTestTargetXctests:testTargetXctests testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
  else {
    [logger log:@"Test failed and no target test results found in the bundle"];
    [reporter testManagerMediator:nil testCaseDidFailForTestClass:@"" method:@"" withMessage:@"" file:nil line:0];
  }
}

+ (void)reportSelectedTests:(NSArray<NSDictionary *> *)selectedTests
             testBundleName:(NSString *)testBundleName
                   reporter:(id<FBTestManagerTestReporter>)reporter
                      queue:(dispatch_queue_t)queue
           resultBundlePath:(NSString *)resultBundlePath
                     logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(selectedTests, @"selectedTests is nil");
  NSAssert([selectedTests isKindOfClass:NSArray.class], @"selectedTests not a NSArray");

  for (NSDictionary *selectedTest in selectedTests) {
    [self reportSelectedTest:selectedTest testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (void)reportTargetTest:(NSDictionary<NSString *, NSDictionary *> *)targetTest
                reporter:(id<FBTestManagerTestReporter>)reporter
                   queue:(dispatch_queue_t)queue
        resultBundlePath:(NSString *)resultBundlePath
                  logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(targetTest, @"targetTest is nil");
  NSAssert([targetTest isKindOfClass:NSDictionary.class], @"targetTest not a NSDictionary");
  NSString *testBundleName = (NSString *)unwrapValue(targetTest[@"targetName"]);

  NSArray<NSDictionary *> *selectedTests = unwrapValues(targetTest[@"tests"]);
  if (selectedTests != nil) {
    [self reportSelectedTests:selectedTests testBundleName:testBundleName reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
  else {
    [logger log:@"Test failed and no test results found in the bundle"];
    NSArray *failureSummaries = unwrapValues(targetTest[@"failureSummaries"]);
    [reporter testManagerMediator:nil testCaseDidFailForTestClass:@"" method:@"" withMessage:[self buildErrorMessage:failureSummaries] file:nil line:0];
  }
}

+ (void)reportTargetTests:(NSArray<NSDictionary *> *)targetTests
                 reporter:(id<FBTestManagerTestReporter>)reporter
                    queue:(dispatch_queue_t)queue
         resultBundlePath:(NSString *)resultBundlePath
                   logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(targetTests, @"targetTests is nil");
  NSAssert([targetTests isKindOfClass:NSArray.class], @"targetTests not a NSArray");

  for (NSDictionary<NSString *, NSDictionary *> *targetTest in targetTests) {
    [self reportTargetTest:targetTest reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (void)reportResults:(NSDictionary<NSString *, NSDictionary *> *)results
             reporter:(id<FBTestManagerTestReporter>)reporter
                queue:(dispatch_queue_t)queue
     resultBundlePath:(NSString *)resultBundlePath
               logger:(id<FBControlCoreLogger>)logger
{
  NSAssert([results isKindOfClass:NSDictionary.class], @"Test results not a NSDictionary");
  NSArray<NSDictionary *> *testTargets = unwrapValues(results[@"testableSummaries"]);

  [self reportTargetTests:testTargets reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
}

+ (void)reportSummaries:(NSArray<NSDictionary *> *)summaries
               reporter:(id<FBTestManagerTestReporter>)reporter
                  queue:(dispatch_queue_t)queue
       resultBundlePath:(NSString *)resultBundlePath
                 logger:(id<FBControlCoreLogger>)logger
{
  NSAssert(summaries, @"Test summaries have no value");
  NSAssert([summaries isKindOfClass:NSArray.class], @"Test summary values not a NSArray");

  for (NSDictionary<NSString *, NSDictionary *> *summary in summaries) {
    [self reportResults:summary reporter:reporter queue:queue resultBundlePath:resultBundlePath logger:logger];
  }
}

+ (NSString *)parseTestsRef:(NSDictionary<NSString *, NSDictionary *> *)testsRef
{
  NSAssert(testsRef, @"tests ref is nil");
  NSAssert([testsRef isKindOfClass:NSDictionary.class], @"tests ref not a NSDictionary");

  return (NSString *)unwrapValue(testsRef[@"id"]);
}

+ (NSString *)parseActionResult:(NSDictionary<NSString *, NSDictionary *> *)actionResult
{
  NSAssert(actionResult, @"action result is nil");
  NSAssert([actionResult isKindOfClass:NSDictionary.class], @"action result not a NSDictionary");

  NSDictionary<NSString *, NSDictionary *> *testsRef = actionResult[@"testsRef"];
  return [self parseTestsRef:testsRef];
}

+ (NSString *)parseAction:(NSDictionary<NSString *, NSDictionary *> *)action
{
  NSAssert(action, @"action is nil");
  NSAssert([action isKindOfClass:NSDictionary.class], @"action not a NSDictionary");

  NSDictionary<NSString *, NSDictionary *> *actionResult = action[@"actionResult"];
  return [self parseActionResult:actionResult];
}

+ (NSArray<NSString *> *)parseActions:(NSDictionary<NSString *, NSObject *> *)actions
{
  NSAssert(actions, @"Test actions is nil");
  NSAssert([actions isKindOfClass:NSDictionary.class], @"Test actions not a NSDictionary");

  NSArray<NSDictionary *> *actionValues = unwrapValues(actions);
  NSAssert(actionValues, @"action values is nil");

  NSMutableArray<NSString *> *ids = [[NSMutableArray alloc] init];
  for (NSDictionary<NSString *, NSDictionary *> *action in actionValues) {
    [ids addObject:[self parseAction:action]];
  }
  return ids;
}

#pragma mark FBXCTestCommands Implementation

- (FBFuture<id<FBiOSTargetContinuation>> *)startTestWithLaunchConfiguration:(FBTestLaunchConfiguration *)testLaunchConfiguration reporter:(id<FBTestManagerTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  // Return early and fail if there is already a test run for the device.
  // There should only ever be one test run per-device.
  if (self.operation) {
    return [[FBDeviceControlError
      describeFormat:@"Cannot Start Test Manager with Configuration %@ as it is already running", testLaunchConfiguration]
      failFuture];
  }
  // Terminate the reparented xcodebuild invocations.
  return [[[FBXcodeBuildOperation
    terminateAbandonedXcodebuildProcessesForUDID:self.device.udid processFetcher:self.processFetcher queue:self.device.workQueue logger:logger]
    onQueue:self.device.workQueue fmap:^(id _) {
      // Then start the task. This future will yield when the task has *started*.
      return [self _startTestWithLaunchConfiguration:testLaunchConfiguration logger:logger];
    }]
    onQueue:self.device.workQueue map:^(FBTask *task) {
      // Then wrap the started task, so that we can augment it with logging and adapt it to the FBiOSTargetContinuation interface.
      return [self _testOperationStarted:task configuration:testLaunchConfiguration reporter:reporter logger:logger];
    }];
}

- (NSArray<id<FBiOSTargetContinuation>> *)testOperations
{
  id<FBiOSTargetContinuation> operation = self.operation;
  return operation ? @[operation] : @[];
}

- (FBFuture<NSArray<NSString *> *> *)listTestsForBundleAtPath:(NSString *)bundlePath timeout:(NSTimeInterval)timeout withAppAtPath:(nonnull NSString *)appPath
{
  return [[FBDeviceControlError
    describeFormat:@"Cannot list the tests in bundle %@ as this is not supported on devices", bundlePath]
    failFuture];
}

- (FBFutureContext<NSNumber *> *)transportForTestManagerService
{
  return [[self.device.amDevice
    startTestManagerService]
    onQueue:self.device.workQueue pend:^(FBAMDServiceConnection *connection) {
      return [FBFuture futureWithResult:@(connection.socket)];
    }];
}

#pragma mark Private

- (FBFuture<FBTask *> *)_startTestWithLaunchConfiguration:(FBTestLaunchConfiguration *)configuration logger:(id<FBControlCoreLogger>)logger
{
  NSError *error = nil;
  // Create the .xctestrun file
  NSString *filePath = [self createXCTestRunFileFromConfiguration:configuration error:&error];
  if (!filePath) {
    return [FBDeviceControlError failFutureWithError:error];
  }

  // Find the path to xcodebuild
  NSString *xcodeBuildPath = [FBDeviceXCTestCommands xcodeBuildPathWithError:&error];
  if (!xcodeBuildPath) {
    return [FBDeviceControlError failFutureWithError:error];
  }

  // Create the Task, wrap it and store it.
  return [FBXcodeBuildOperation
    operationWithUDID:self.device.udid
    configuration:configuration
    xcodeBuildPath:xcodeBuildPath
    testRunFilePath:filePath
    queue:self.device.workQueue
    logger:[logger withName:@"xcodebuild"]];
}

- (id<FBiOSTargetContinuation>)_testOperationStarted:(FBTask *)task configuration:(FBTestLaunchConfiguration *)configuration reporter:(id<FBTestManagerTestReporter>)reporter logger:(id<FBControlCoreLogger>)logger
{
  FBFuture<NSNull *> *completed = [[[[task
    completed]
    onQueue:self.device.workQueue fmap:^FBFuture<NSNull *> *(id _) {
      // This will execute only if the operation completes successfully.
      [logger logFormat:@"xcodebuild operation completed successfully %@", task];
      if (configuration.resultBundlePath) {
        [logger logFormat:@"Parsing the result bundle %@", configuration.resultBundlePath];

        NSString *testSummariesPath = [configuration.resultBundlePath stringByAppendingPathComponent:@"TestSummaries.plist"];
        NSDictionary<NSString *, NSArray *> *results = [NSDictionary dictionaryWithContentsOfFile:testSummariesPath];
        NSString *resultBundleInfoPath = [configuration.resultBundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary<NSString *, NSObject *> *bundleInfo = [NSDictionary dictionaryWithContentsOfFile:resultBundleInfoPath];
        id bundleFormatVersion =[bundleInfo valueForKey:@"version"];

        if (results) {
          [self.class reportResults:results reporter:reporter];
          [logger logFormat:@"ResultBundlePath: %@", configuration.resultBundlePath];
          return FBFuture.empty;
        }
        else if (bundleFormatVersion && [bundleFormatVersion isKindOfClass:NSDictionary.class]) {
          NSNumber *majorVersion = readNumberFromDict(bundleFormatVersion, @"major");
          NSNumber *minorVersion = readNumberFromDict(bundleFormatVersion, @"minor");
          [logger logFormat:@"Test result bundle format version: %@.%@", majorVersion, minorVersion];
          return [[FBXCTestResultToolOperation
            getJSONFrom:configuration.resultBundlePath forId:nil queue:self.device.workQueue logger:logger]
            onQueue:self.device.workQueue fmap:^(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *actionsInvocationRecord) {
              NSDictionary<NSString *, NSArray *> *actions = actionsInvocationRecord[@"actions"];
              NSArray<NSString *> *ids = [self.class parseActions:actions];
              NSMutableArray<FBFuture *> *operations = NSMutableArray.array;
              for (NSString *bundleObjectId in ids) {
                FBFuture *operation = [[FBXCTestResultToolOperation
                  getJSONFrom:configuration.resultBundlePath forId:bundleObjectId queue:self.device.workQueue logger:logger]
                  onQueue:self.device.workQueue doOnResolved:^void (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *xcresults) {
                    NSArray<NSDictionary *> *summaries = unwrapValues(xcresults[@"summaries"]);
                    [self.class reportSummaries:summaries reporter:reporter queue:self.device.asyncQueue resultBundlePath:configuration.resultBundlePath logger:logger];
                  }];
                [operations addObject:operation];
              }
              return [FBFuture futureWithFutures:operations];
            }];
        }
        else {
          NSString *errorMessage = [NSString stringWithFormat:@"No test results were produced for Configuration:\n\n%@", configuration];
          [reporter testManagerMediator:nil testPlanDidFailWithMessage:errorMessage];
          return FBFuture.empty;
        }
      }
      [logger log:@"No result bundle to parse"];
      return FBFuture.empty;
    }]
    onQueue:self.device.workQueue fmap:^(id _) {
      [reporter testManagerMediatorDidFinishExecutingTestPlan:nil];
      return FBFuture.empty;
    }]
    onQueue:self.device.workQueue chain:^(FBFuture *future) {
      // Always perform this, whether the operation was successful or not.
      [logger logFormat:@"Test Operation has completed for %@, with state '%@' removing it as the sole operation for this target", future, configuration.shortDescription];
      self.operation = nil;
      return future;
    }];

  self.operation = FBiOSTargetContinuationNamed(completed, FBiOSTargetFutureTypeTestOperation);
  [logger logFormat:@"Test Operation %@ has started for %@, storing it as the sole operation for this target", task, configuration.shortDescription];

  return self.operation;
}

+ (NSDictionary<NSString *, id> *)overwriteXCTestRunPropertiesWithBaseProperties:(NSDictionary<NSString *, id> *)baseProperties newProperties:(NSDictionary<NSString *, id> *)newProperties
{
  NSMutableDictionary<NSString *, id> *mutableTestRunProperties = [baseProperties mutableCopy];
  for (NSString *testId in mutableTestRunProperties) {
    NSMutableDictionary<NSString *, id> *mutableTestProperties = [[mutableTestRunProperties objectForKey:testId] mutableCopy];
    NSDictionary<NSString *, id> *defaultTestProperties = [newProperties objectForKey:@"StubBundleId"];
    for (id key in defaultTestProperties) {
      if ([mutableTestProperties objectForKey:key]) {
        mutableTestProperties[key] =  [defaultTestProperties objectForKey:key];
      }
    }
    mutableTestRunProperties[testId] = mutableTestProperties;
  }
  return [mutableTestRunProperties copy];
}

- (nullable NSString *)createXCTestRunFileFromConfiguration:(FBTestLaunchConfiguration *)configuration error:(NSError **)error
{
  NSString *fileName = [NSProcessInfo.processInfo.globallyUniqueString stringByAppendingPathExtension:@"xctestrun"];
  NSString *path = [self.workingDirectory stringByAppendingPathComponent:fileName];

  NSDictionary<NSString *, id> *defaultTestRunProperties = [FBXcodeBuildOperation xctestRunProperties:configuration];

  NSDictionary<NSString *, id> *testRunProperties = configuration.xcTestRunProperties
    ? [FBDeviceXCTestCommands overwriteXCTestRunPropertiesWithBaseProperties:configuration.xcTestRunProperties newProperties:defaultTestRunProperties]
    : defaultTestRunProperties;

  if (![testRunProperties writeToFile:path atomically:false]) {
    return [[FBDeviceControlError
      describeFormat:@"Failed to write to file %@", path]
      fail:error];
  }
  return path;
}

+ (NSString *)xcodeBuildPathWithError:(NSError **)error
{
  NSString *path = [FBXcodeConfiguration.developerDirectory stringByAppendingPathComponent:@"/usr/bin/xcodebuild"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
    return [[FBDeviceControlError
      describeFormat:@"xcodebuild does not exist at expected path %@", path]
      fail:error];
  }
  return path;
}

// This replicates the stdout from xcodebuild, but without all the garbage that xcodebuild outputs
// This works before Xcode 11
+ (void)addTestLogsFromLegacyActivitySummary:(NSDictionary *)activitySummary logs:(NSMutableArray<NSString *> *)logs testStartTimeInterval:(double)testStartTimeInterval indent:(NSUInteger)indent
{

  NSAssert([activitySummary isKindOfClass:NSDictionary.class], @"activitySummary not a NSDictionary");
  NSString *message = readStringFromDict(activitySummary, @"Title");
  double startTimeInterval = readDoubleFromDict(activitySummary, @"StartTimeInterval");
  double elapsed = startTimeInterval - testStartTimeInterval;
  NSString *indentString = [@"" stringByPaddingToLength:1 + indent * 4 withString:@" " startingAtIndex:0];
  NSString *log = [NSString stringWithFormat:@"    t = %8.2fs%@%@", elapsed, indentString, message];
  [logs addObject:log];

  NSArray<NSDictionary *> *subActivities = (NSArray<NSDictionary *> *) activitySummary[@"SubActivities"];
  if (!subActivities) {
    return;
  }
  NSAssert([subActivities isKindOfClass:NSArray.class], @"subActivities is not a NSArray");

  for (NSDictionary *subActivity in subActivities) {
    [self addTestLogsFromLegacyActivitySummary:subActivity logs:logs testStartTimeInterval:testStartTimeInterval indent:indent + 1];
  }
}

// This works before Xcode 11
+ (NSMutableArray<NSString *> *)buildTestLogLegacy:(NSArray<NSDictionary *> *)activitySummaries
                                    testBundleName:(NSString *)testBundleName
                                     testClassName:(NSString *)testClassName
                                    testMethodName:(NSString *)testMethodName
                                        testPassed:(BOOL)testPassed
                                          duration:(double)duration
{
  NSMutableArray *logs = [NSMutableArray array];
  NSString *testCaseFullName = [NSString stringWithFormat:@"-[%@.%@ %@]", testBundleName, testClassName, testMethodName];
  [logs addObject:[NSString stringWithFormat:@"Test Case '%@' started.", testCaseFullName]];

  double testStartTimeInterval = 0;
  BOOL startTimeSet = NO;
  for (NSDictionary *activitySummary in activitySummaries) {
    if (!startTimeSet) {
      testStartTimeInterval = readDoubleFromDict(activitySummary, @"StartTimeInterval");
      startTimeSet = YES;
    }

    NSString *activityType = readStringFromDict(activitySummary, @"ActivityType");
    if ([activityType isEqualToString:@"com.apple.dt.xctest.activity-type.internal"]) {
      [self addTestLogsFromLegacyActivitySummary:activitySummary logs:logs testStartTimeInterval:testStartTimeInterval indent:0];
    }
  }

  [logs addObject:[NSString stringWithFormat:@"Test Case '%@' %@ in %.3f seconds", testCaseFullName, testPassed ? @"passed" : @"failed", duration]];
  return logs;
}

+ (void)addTestLogsFromActivitySummary:(NSDictionary *)activitySummary logs:(NSMutableArray<NSString *> *)logs testStartTimeInterval:(double)testStartTimeInterval indent:(NSUInteger)indent
{
  NSAssert([activitySummary isKindOfClass:NSDictionary.class], @"activitySummary not a NSDictionary");
  NSString *message = (NSString *)unwrapValue(activitySummary[@"title"]);
  NSDate *date = dateFromString((NSString *)unwrapValue(activitySummary[@"start"]));
  double startTimeInterval = [date timeIntervalSince1970];
  double elapsed = startTimeInterval - testStartTimeInterval;
  NSString *indentString = [@"" stringByPaddingToLength:1 + indent * 4 withString:@" " startingAtIndex:0];
  NSString *log = [NSString stringWithFormat:@"    t = %8.2fs%@%@", elapsed, indentString, message];
  [logs addObject:log];

  NSDictionary<NSString *, NSObject *> *wrappedSubActivities = activitySummary[@"subactivities"];
  if (!wrappedSubActivities) {
    return;
  }
  NSArray<NSDictionary *> *subActivities = unwrapValues(wrappedSubActivities);
  NSAssert([subActivities isKindOfClass:NSArray.class], @"subActivities is not a NSArray");

  for (NSDictionary *subActivity in subActivities) {
    [self addTestLogsFromActivitySummary:subActivity logs:logs testStartTimeInterval:testStartTimeInterval indent:indent + 1];
  }
}

+ (NSMutableArray<NSString *> *)buildTestLog:(NSArray<NSDictionary *> *)activitySummaries
                              testBundleName:(NSString *)testBundleName
                               testClassName:(NSString *)testClassName
                              testMethodName:(NSString *)testMethodName
                                  testPassed:(BOOL)testPassed
                                    duration:(double)duration
{
  NSMutableArray *logs = [NSMutableArray array];
  NSString *testCaseFullName = [NSString stringWithFormat:@"-[%@.%@ %@]", testBundleName, testClassName, testMethodName];
  [logs addObject:[NSString stringWithFormat:@"Test Case '%@' started.", testCaseFullName]];

  double testStartTimeInterval = 0;
  BOOL startTimeSet = NO;
  for (NSDictionary *activitySummary in activitySummaries) {
    if (!startTimeSet) {
      NSDate *date = dateFromString((NSString *)unwrapValue(activitySummary[@"start"]));
      testStartTimeInterval = [date timeIntervalSince1970];
      startTimeSet = YES;
    }

    NSString *activityType = (NSString *)unwrapValue(activitySummary[@"activityType"]);
    if ([activityType isEqualToString:@"com.apple.dt.xctest.activity-type.internal"]) {
      [self addTestLogsFromActivitySummary:activitySummary logs:logs testStartTimeInterval:testStartTimeInterval indent:0];
    }
  }

  [logs addObject:[NSString stringWithFormat:@"Test Case '%@' %@ in %.3f seconds", testCaseFullName, testPassed ? @"passed" : @"failed", duration]];
  return logs;
}

+ (void)extractScreenshotsFromAttachments:(NSArray<NSDictionary *> *)attachments
                                       to:(NSString *)destination
                                    queue:(dispatch_queue_t)queue
                         resultBundlePath:(NSString *)resultBundlePath
                                   logger:(id<FBControlCoreLogger>)logger
{
  NSError *error = nil;
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^Screenshot_.*\\.jpg$" options:0 error:&error];
  NSAssert(regex, @"Screenshot filename regex failed to compile %@", error);
  for (NSDictionary<NSString *, NSDictionary *> *attachment in attachments) {
    if (attachment[@"filename"]) {
      NSString *filename = (NSString *)unwrapValue(attachment[@"filename"]);
      NSTextCheckingResult *matchResult = [regex firstMatchInString:filename options:0 range:NSMakeRange(0, [filename length])];
      if (attachment[@"payloadRef"] && matchResult) {
        NSString *timestamp = (NSString *)unwrapValue(attachment[@"timestamp"]);
        NSString *exportPath = [destination stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", timestamp, filename]];
        NSDictionary<NSString *, NSDictionary *> *payloadRef = attachment[@"payloadRef"];
        NSAssert(payloadRef, @"Screenshot payload reference is empty");
        NSString *screenshotId = (NSString *)unwrapValue(payloadRef[@"id"]);
        [[FBXCTestResultToolOperation exportFileFrom:resultBundlePath to:exportPath forId:screenshotId queue:queue logger:logger] await:nil];
      }
    }
  }
}

+ (NSString *)extractScreenshotsFromActivities:(NSArray<NSDictionary *> *)activities
                                         queue:(dispatch_queue_t)queue
                              resultBundlePath:(NSString *)resultBundlePath
                                        logger:(id<FBControlCoreLogger>)logger
{
  NSError *error = nil;

  NSFileManager *fileManager = NSFileManager.defaultManager;
  // Extract all screenshots to the "Attachments" folder just as in the legacy test result bundle
  NSString *screenshotsPath = [resultBundlePath stringByAppendingPathComponent:@"Attachments"];
  BOOL isDirectory = NO;
  if ([fileManager fileExistsAtPath:screenshotsPath isDirectory:&isDirectory]) {
    if (!isDirectory) {
      return [[FBControlCoreError describeFormat:@"%@ is not a directory", screenshotsPath] fail:&error];
    }
  } else {
    if (![fileManager createDirectoryAtPath:screenshotsPath withIntermediateDirectories:NO attributes:nil error:&error]) {
      return [[FBControlCoreError describeFormat:@"Failed to create directory at %@", screenshotsPath] fail:&error];
    }
  }

  for (NSDictionary *activity in activities) {
    if (activity[@"attachments"]) {
      NSArray<NSDictionary *> *attachments = unwrapValues(activity[@"attachments"]);
      [self extractScreenshotsFromAttachments:attachments to:screenshotsPath queue:queue resultBundlePath:resultBundlePath logger:logger];
    }
    if (activity[@"subactivities"]) {
      NSArray<NSDictionary *> *subactivities = unwrapValues(activity[@"subactivities"]);
      [self extractScreenshotsFromActivities:subactivities queue:queue resultBundlePath:resultBundlePath logger:logger];
    }
  }

  return screenshotsPath;
}

// This works before Xcode 11
+ (NSString *)buildErrorMessageLegacy:(NSArray<NSDictionary *> *)failureSummmaries {
  NSMutableArray *messages = [NSMutableArray array];
  for (NSDictionary *failureSummary in failureSummmaries) {
    NSAssert([failureSummary isKindOfClass:NSDictionary.class], @"failureSummary is not a NSDictionary");
    [messages addObject:readStringFromDict(failureSummary, @"Message")];
  }

  return [messages componentsJoinedByString:@"\n"];
}

+ (NSString *)buildErrorMessage:(NSArray<NSDictionary *> *)failureSummmaries {
  NSMutableArray *messages = [NSMutableArray array];
  for (NSDictionary *failureSummary in failureSummmaries) {
    NSAssert([failureSummary isKindOfClass:NSDictionary.class], @"failureSummary is not a NSDictionary");
    [messages addObject:(NSString *)unwrapValue(failureSummary[@"message"])];
  }

  return [messages componentsJoinedByString:@"\n"];
}

@end
