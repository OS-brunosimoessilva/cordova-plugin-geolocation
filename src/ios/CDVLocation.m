/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVLocation.h"

#pragma mark Constants

#define kPGLocationErrorDomain @"kPGLocationErrorDomain"
#define kPGLocationDesiredAccuracyKey @"desiredAccuracy"
#define kPGLocationForcePromptKey @"forcePrompt"
#define kPGLocationDistanceFilterKey @"distanceFilter"
#define kPGLocationFrequencyKey @"frequency"

#pragma mark -
#pragma mark Categories

@implementation CDVLocationData

@synthesize locationStatus, locationInfo, locationCallbacks, watchCallbacks;
- (CDVLocationData*)init
{
    self = (CDVLocationData*)[super init];
    if (self) {
        self.locationInfo = nil;
        self.locationCallbacks = nil;
        self.watchCallbacks = nil;
    }
    return self;
}

@end

#pragma mark -
#pragma mark CDVLocation

@implementation CDVLocation

@synthesize locationManager, locationData;

- (void)pluginInitialize
{
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    __locationStarted = NO;
    __highAccuracyEnabled = NO;
    self.locationData = nil;
}

- (BOOL)isAuthorized
{
    NSUInteger authStatus = [self.locationManager authorizationStatus];
    return (authStatus == kCLAuthorizationStatusAuthorizedWhenInUse) ||
           (authStatus == kCLAuthorizationStatusAuthorizedAlways) ||
           (authStatus == kCLAuthorizationStatusNotDetermined);
}

- (void)isLocationServicesEnabledWithCompletion:(void (^)(BOOL enabled))completion {
    if (!completion) {
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL isEnabled = [CLLocationManager locationServicesEnabled];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(isEnabled);
        });
    });
}

- (void)startLocation:(BOOL)enableHighAccuracy
{
    __weak __typeof(self) weakSelf = self;

    [self isLocationServicesEnabledWithCompletion:^(BOOL enabled) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!enabled) {
            [strongSelf returnLocationError:PERMISSIONDENIED withMessage:@"Location services are not enabled."];
            return;
        }

        if (![strongSelf isAuthorized]) {
            [strongSelf handleAuthorizationError];
            return;
        }

        if ([strongSelf.locationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
            [strongSelf requestLocationAuthorization:enableHighAccuracy];
            return;
        }

        [strongSelf configureLocationUpdatesWithHighAccuracy:enableHighAccuracy];
    }];
}

- (void)handleAuthorizationError
{
    NSString *message = nil;
    CLAuthorizationStatus authStatus = [self.locationManager authorizationStatus];

    switch (authStatus) {
        case kCLAuthorizationStatusNotDetermined:
            message = @"User undecided on application's use of location services.";
            break;
        case kCLAuthorizationStatusRestricted:
            message = @"Application's use of location services is restricted.";
            break;
        default:
            message = @"Authorization denied for location services.";
            break;
    }

    [self returnLocationError:PERMISSIONDENIED withMessage:message];
}

- (void)requestLocationAuthorization:(BOOL)enableHighAccuracy
{
    self->__highAccuracyEnabled = enableHighAccuracy;

    if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationWhenInUseUsageDescription"]) {
        [self.locationManager requestWhenInUseAuthorization];
    } else if ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSLocationAlwaysUsageDescription"]) {
        [self.locationManager requestAlwaysAuthorization];
    } else {
        NSLog(@"[Warning] No NSLocationWhenInUseUsageDescription or NSLocationAlwaysUsageDescription key is defined in the Info.plist file.");
    }
}

- (void)configureLocationUpdatesWithHighAccuracy:(BOOL)enableHighAccuracy
{
    [self.locationManager stopUpdatingLocation];
    self->__locationStarted = YES;

    if (enableHighAccuracy) {
        self->__highAccuracyEnabled = YES;
        self.locationManager.distanceFilter = 5;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    } else {
        self->__highAccuracyEnabled = NO;
        self.locationManager.distanceFilter = 10;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    }

    [self.locationManager startUpdatingLocation];
}


- (void)_stopLocation
{
    if (__locationStarted) {
        __weak __typeof(self) weakSelf = self;
        
        [self isLocationServicesEnabledWithCompletion:^(BOOL enabled) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !enabled) {
                return;
            }
            
            [strongSelf.locationManager stopUpdatingLocation];
            strongSelf->__locationStarted = NO;
            strongSelf->__highAccuracyEnabled = NO;
        }];
    }
}

- (void)locationManager:(CLLocationManager *)manager
    didUpdateToLocation:(CLLocation *)newLocation
           fromLocation:(CLLocation *)oldLocation
{
    CDVLocationData *cData = self.locationData;
    cData.locationInfo = newLocation;

    [self processLocationCallbacks];

    if (self.locationData.watchCallbacks.count > 0) {
        [self processWatchCallbacks];
    } else {
        [self _stopLocation];
    }
}

- (void)processLocationCallbacks
{
    if (self.locationData.locationCallbacks.count > 0) {
        for (NSString *callbackId in self.locationData.locationCallbacks) {
            [self returnLocationInfo:callbackId andKeepCallback:NO];
        }

        [self.locationData.locationCallbacks removeAllObjects];
    }
}

- (void)processWatchCallbacks
{
    for (NSString *timerId in self.locationData.watchCallbacks) {
        NSString *callbackId = [self.locationData.watchCallbacks objectForKey:timerId];
        [self returnLocationInfo:callbackId andKeepCallback:YES];
    }
}

- (void)getLocation:(CDVInvokedUrlCommand *)command
{
    [self.commandDelegate runInBackground:^{
        __weak __typeof(self) weakSelf = self;
        NSString *callbackId = command.callbackId;
        BOOL enableHighAccuracy = [[command argumentAtIndex:0] boolValue];

        [self isLocationServicesEnabledWithCompletion:^(BOOL enabled) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            if (!enabled) {
                [strongSelf returnLocationError:PERMISSIONDENIED withMessage:@"Location services are disabled."];
                return;
            }

            [strongSelf prepareLocationData];
            
            if (!strongSelf->__locationStarted || strongSelf->__highAccuracyEnabled != enableHighAccuracy) {
                if (callbackId) {
                    [strongSelf.locationData.locationCallbacks addObject:callbackId];
                }
                [strongSelf startLocation:enableHighAccuracy];
            } else {
                [strongSelf returnLocationInfo:callbackId andKeepCallback:NO];
            }
        }];
    }];
}

- (void)addWatch:(CDVInvokedUrlCommand *)command
{
    __weak __typeof(self) weakSelf = self;
    NSString *callbackId = command.callbackId;
    NSString *timerId = [command argumentAtIndex:0];
    BOOL enableHighAccuracy = [[command argumentAtIndex:1] boolValue];

    [self prepareLocationData];

    self.locationData.watchCallbacks[timerId] = callbackId;

    [self isLocationServicesEnabledWithCompletion:^(BOOL enabled) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (!enabled) {
            [strongSelf returnLocationError:PERMISSIONDENIED withMessage:@"Location services are disabled."];
            return;
        }

        if (!strongSelf->__locationStarted || strongSelf->__highAccuracyEnabled != enableHighAccuracy) {
            [strongSelf startLocation:enableHighAccuracy];
        }
    }];
}

- (void)clearWatch:(CDVInvokedUrlCommand *)command
{
    NSString *timerId = [command argumentAtIndex:0];

    if (self.locationData && self.locationData.watchCallbacks[timerId]) {
        [self.locationData.watchCallbacks removeObjectForKey:timerId];

        if (self.locationData.watchCallbacks.count == 0) {
            [self _stopLocation];
        }
    }
}

- (void)prepareLocationData
{
    if (!self.locationData) {
        self.locationData = [[CDVLocationData alloc] init];
    }

    if (!self.locationData.locationCallbacks) {
        self.locationData.locationCallbacks = [NSMutableArray array];
    }

    if (!self.locationData.watchCallbacks) {
        self.locationData.watchCallbacks = [NSMutableDictionary dictionary];
    }
}


- (void)stopLocation:(CDVInvokedUrlCommand*)command
{
    [self _stopLocation];
}

- (void)returnLocationInfo:(NSString *)callbackId andKeepCallback:(BOOL)keepCallback
{
    CDVLocationData *lData = self.locationData;

    if (!lData || !lData.locationInfo) {
        [self sendPluginResultError:POSITIONUNAVAILABLE callbackId:callbackId];
        return;
    }

    CLLocation *location = lData.locationInfo;
    NSMutableDictionary *locationInfo = [NSMutableDictionary dictionaryWithCapacity:8];

    locationInfo[@"timestamp"] = @([location.timestamp timeIntervalSince1970] * 1000);
    locationInfo[@"velocity"] = @(location.speed);
    locationInfo[@"altitudeAccuracy"] = @(location.verticalAccuracy);
    locationInfo[@"accuracy"] = @(location.horizontalAccuracy);
    locationInfo[@"heading"] = @(location.course);
    locationInfo[@"altitude"] = @(location.altitude);

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.maximumFractionDigits = 15;
    formatter.roundingMode = NSNumberFormatterRoundUp;

    locationInfo[@"latitude"] = [formatter numberFromString:[formatter stringFromNumber:@(location.coordinate.latitude)]];
    locationInfo[@"longitude"] = [formatter numberFromString:[formatter stringFromNumber:@(location.coordinate.longitude)]];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:locationInfo];
    [result setKeepCallbackAsBool:keepCallback];

    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)returnLocationError:(NSUInteger)errorCode withMessage:(NSString *)message
{
    NSMutableDictionary *errorInfo = [NSMutableDictionary dictionaryWithCapacity:2];
    errorInfo[@"code"] = @(errorCode);
    errorInfo[@"message"] = message ?: @"";

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:errorInfo];

    [self sendResultToCallbacks:result callbacks:self.locationData.locationCallbacks];
    [self.locationData.locationCallbacks removeAllObjects];

    [self sendResultToCallbacks:result callbacks:self.locationData.watchCallbacks.allValues];
}

- (void)sendResultToCallbacks:(CDVPluginResult *)result callbacks:(NSArray<NSString *> *)callbacks
{
    for (NSString *callbackId in callbacks) {
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
}

- (void)sendPluginResultError:(NSUInteger)errorCode callbackId:(NSString *)callbackId
{
    NSMutableDictionary *errorInfo = [NSMutableDictionary dictionaryWithCapacity:2];
    errorInfo[@"code"] = @(errorCode);
    errorInfo[@"message"] = @"";

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:errorInfo];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}


- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    NSLog(@"locationManager::didFailWithError: %@", error.localizedFailureReason ?: @"No failure reason provided");

    if (!self.locationData || !__locationStarted) {
        return;
    }

    // PositionError.PERMISSION_DENIED = 1;
    // PositionError.POSITION_UNAVAILABLE = 2;
    // PositionError.TIMEOUT = 3;
    NSUInteger positionError = (error.code == kCLErrorDenied) ? PERMISSIONDENIED : POSITIONUNAVAILABLE;

    [self returnLocationError:positionError withMessage:error.localizedDescription ?: @"Unknown error occurred"];

    if (error.code != kCLErrorLocationUnknown) {
        [self.locationManager stopUpdatingLocation];
        __locationStarted = NO;
    }
}


//iOS8+
-(void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if(!__locationStarted){
        [self startLocation:__highAccuracyEnabled];
    }
}

- (void)dealloc
{
    self.locationManager.delegate = nil;
}

- (void)onReset
{
    [self _stopLocation];
    [self.locationManager stopUpdatingHeading];
}

@end
