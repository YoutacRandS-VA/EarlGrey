//
// Copyright 2019 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "GREYVisibilityChecker.h"

#import <CoreGraphics/CoreGraphics.h>

#import "NSObject+GREYCommon.h"
#import "GREYLogger.h"
#import "CGGeometry+GREYUI.h"
#import "GREYQuickVisibilityChecker.h"
#import "GREYThoroughVisibilityChecker.h"
#import "GREYVisibilityCheckerCacheEntry.h"

/**
 * The minimum number of points that must be visible along with the activation point to consider an
 * element visible. It is non-static to make it visible in tests.
 */
const NSUInteger kMinimumPointsVisibleForInteraction = 10;

/**
 * Cache for storing recent visibility checks. This cache is invalidated on every runloop spin.
 */
static NSMapTable<NSString *, GREYVisibilityCheckerCacheEntry *> *gCache;

#pragma mark - GREYVisibilityChecker

@implementation GREYVisibilityChecker

+ (BOOL)isNotVisible:(id)element {
  return [self percentVisibleAreaOfElement:element] == 0;
}

+ (CGFloat)percentVisibleAreaOfElement:(id)element {
  if (!element) {
    return 0;
  }

  GREYVisibilityCheckerCacheEntry *cache = [self grey_cacheForElementCreateIfNonExistent:element];
  NSNumber *percentVisible = [cache visibleAreaPercent];
  if (percentVisible) {
    return [percentVisible floatValue];
  }

  GREYLogVerbose(@"GREYVisibilityChecker starts calculating visible area for element: %@",
                 [element grey_description]);
  // Fallback set to YES means we should use the slow visibility checker.
  BOOL fallback = NO;
  CGFloat result = [GREYQuickVisibilityChecker percentVisibleAreaOfElement:element
                                                           performFallback:&fallback];

  if (fallback) {
    result = [GREYThoroughVisibilityChecker percentVisibleAreaOfElement:element];
  }
  cache.visibleAreaPercent = @(result);
  GREYLogVerbose(
      @"GREYVisibilityChecker completes calculating visble area %@ fallback. The result is %.3f%.",
      fallback ? @"with" : @"without", result * 100);
  return result;
}

+ (CGPoint)visibleInteractionPointForElement:(id)element {
  if (!element) {
    // Nil elements are not considered visible for interaction.
    return GREYCGPointNull;
  }

  GREYVisibilityCheckerCacheEntry *cache = [self grey_cacheForElementCreateIfNonExistent:element];
  NSValue *cachedPointValue = [cache visibleInteractionPoint];
  if (cachedPointValue) {
    return [cachedPointValue CGPointValue];
  }
  GREYLogVerbose(@"GREYVisibilityChecker starts looking for interaction point for element: %@",
                 [element grey_description]);
  // Fallback set to YES means we should use the slow visibility checker.
  BOOL fallback = NO;
  CGPoint result = [GREYQuickVisibilityChecker visibleInteractionPointForElement:element
                                                                 performFallback:&fallback];
  if (fallback) {
    result = [GREYThoroughVisibilityChecker visibleInteractionPointForElement:element];
  }
  cache.visibleInteractionPoint = [NSValue valueWithCGPoint:result];
  GREYLogVerbose(@"GREYVisibilityChecker completes looking for interaction point %@ fallback. The "
                 @"result is (%.3f, %.3f).",
                 fallback ? @"with" : @"without", result.x, result.y);
  return result;
}

+ (CGRect)rectEnclosingVisibleAreaOfElement:(id)element {
  GREYVisibilityCheckerCacheEntry *cache = [self grey_cacheForElementCreateIfNonExistent:element];
  NSValue *rectValue = [cache rectEnclosingVisibleArea];
  if (rectValue) {
    return [rectValue CGRectValue];
  }
  CGRect visibleAreaRect =
      [GREYThoroughVisibilityChecker rectEnclosingVisibleAreaOfElement:element];
  cache.rectEnclosingVisibleArea = [NSValue valueWithCGRect:visibleAreaRect];
  return visibleAreaRect;
}

#pragma mark - Private

/**
 * @return The cached key for an @c element.
 */
+ (NSString *)grey_keyForElement:(id)element {
  return [NSString stringWithFormat:@"%p", element];
}

/**
 * Saves a cache @c entry for an @c element and adds it for invalidation on the next runloop drain.
 *
 * @param entry   The cache entry to be saved.
 * @param element The element to which the entry is associated.
 */
+ (void)grey_addCache:(GREYVisibilityCheckerCacheEntry *)entry forElement:(id)element {
  if (!gCache) {
    gCache = [NSMapTable strongToStrongObjectsMapTable];
  }

  // Get the pointer value and store it as a string.
  NSString *elementKey = [self grey_keyForElement:element];
  [gCache setObject:entry forKey:elementKey];

  // Set us up for invalidation on the next runloop drain.
  static BOOL pendingInvalidation = NO;
  if (!pendingInvalidation) {
    pendingInvalidation = YES;
    void (^observerBlock)(CFRunLoopObserverRef observer, CFRunLoopActivity activity) =
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
          [GREYVisibilityChecker grey_invalidateCache];
          pendingInvalidation = NO;
          CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, kCFRunLoopDefaultMode);
          CFRelease(observer);
        };
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopBeforeSources, false, LONG_MAX, observerBlock);
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopDefaultMode);
  }
}

/**
 * Returns cached value for an @c element. Modifying the returned cache also modifies it in the
 * backing store so any changes are visible next time cache is fetched for the same @c element,
 * provided the cache is still valid.
 *
 * @param element The element whose cache is being queried.
 *
 * @return The cached stored under the given @c element.
 */
+ (GREYVisibilityCheckerCacheEntry *)grey_cacheForElementCreateIfNonExistent:(id)element {
  if (!element) {
    return nil;
  }
  GREYVisibilityCheckerCacheEntry *entry;
  if (gCache) {
    NSString *elementKey = [self grey_keyForElement:element];
    entry = [gCache objectForKey:elementKey];
  }

  if (!entry) {
    entry = [[GREYVisibilityCheckerCacheEntry alloc] init];
    [self grey_addCache:entry forElement:element];
  }
  return entry;
}

/**
 * Invalidates the global cache of visibility checks.
 */
+ (void)grey_invalidateCache {
  [gCache removeAllObjects];
}

#pragma mark - Package Internal

+ (void)resetVisibilityImages {
  [GREYThoroughVisibilityChecker resetVisibilityImages];
}

+ (UIImage *)grey_lastActualBeforeImage {
  return [GREYThoroughVisibilityChecker lastActualBeforeImage];
}

+ (UIImage *)grey_lastActualAfterImage {
  return [GREYThoroughVisibilityChecker lastActualAfterImage];
}

+ (UIImage *)grey_lastExpectedAfterImage {
  return [GREYThoroughVisibilityChecker lastExpectedAfterImage];
}

@end
