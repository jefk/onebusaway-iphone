/**
 * Copyright (C) 2009 bdferris <bdferris@onebusaway.org>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "OBASearchResultsMapViewController.h"
#import "OBARoute.h"
#import "OBAStopV2.h"
#import "OBARouteV2.h"
#import "OBAAgencyWithCoverageV2.h"
#import "OBAGenericAnnotation.h"
#import "OBAAgencyWithCoverage.h"
#import "OBANavigationTargetAnnotation.h"
#import "OBASphericalGeometryLibrary.h"
#import "OBAProgressIndicatorView.h"
#import "OBASearchResultsListViewController.h"
#import "OBABookmarksViewController.h"
#import "OBARecentStopsViewController.h"
#import "OBAStopViewController.h"
#import "OBACoordinateBounds.h"
#import "OBALogger.h"
#import "OBAStopIconFactory.h"
#import "OBAPresentation.h"
#import "OBAInfoViewController.h"
#import <QuartzCore/QuartzCore.h>

#define kScopeViewAnimationDuration 0.25
#define kRouteSegmentIndex 0
#define kAddressSegmentIndex 1
#define kStopNumberSegmentIndex 2
#define kMapLabelAnimationDuration 0.25

// Radius in meters
static const double kDefaultMapRadius = 100;
static const double kMinMapRadius = 150;
static const double kMaxLatDeltaToShowStops = 0.008;
static const double kRegionScaleFactor = 1.5;
static const double kMinRegionDeltaToDetectUserDrag = 50;

static const double kRegionChangeRequestsTimeToLive = 3.0;

static const double kMaxMapDistanceFromCurrentLocationForNearby = 800;
static const double kPaddingScaleFactor = 1.075;
static const NSUInteger kShowNClosestStops = 4;

static const double kStopsInRegionRefreshDelayOnDrag = 0.5;
static const double kStopsInRegionRefreshDelayOnLocate = 0.1;

@interface OBASearchResultsMapViewController ()
@property(strong) UIView *activityIndicatorWrapper;
@property(strong) UIActivityIndicatorView * activityIndicatorView;
@property(strong) UIButton *locationButton;
@property(strong) UIBarButtonItem *listBarButtonItem;
@property(strong) OBASearchResultsListViewController *searchResultsListViewController;
@end

@interface OBASearchResultsMapViewController (Private)

- (void) refreshCurrentLocation;

- (void) scheduleRefreshOfStopsInRegion:(NSTimeInterval)interval location:(CLLocation*)location;
- (NSTimeInterval) getRefreshIntervalForLocationAccuracy:(CLLocation*)location;
- (void) refreshStopsInRegion;
- (void) refreshSearchToolbar;

- (void) reloadData;
- (CLLocation*) currentLocation;

- (void) showLocationServicesAlert;

- (void) didCompleteNetworkRequest;

- (void) setAnnotationsFromResults;
- (void) setOverlaysFromResults;
- (void) setRegionFromResults;

- (NSString*) computeSearchFilterString;
- (NSString*) computeLabelForCurrentResults;

- (MKCoordinateRegion) computeRegionForCurrentResults:(BOOL*)needsUpdate;
- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForNClosestStops:(NSArray*)stops center:(CLLocation*)location numberOfStops:(NSUInteger)numberOfStops;
- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops center:(CLLocation*)location;
- (MKCoordinateRegion) computeRegionForNearbyStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks andStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForAgenciesWithCoverage:(NSArray*)agenciesWithCoverage;

- (MKCoordinateRegion) getLocationAsRegion:(CLLocation*)location;

- (void) checkResults;
- (BOOL) checkOutOfRangeResults;
- (void) checkNoRouteResults;
- (void) checkNoPlacemarksResults;
- (void) showNoResultsAlertWithTitle:(NSString*)title prompt:(NSString*)prompt;
- (BOOL) controllerIsVisibleAndActive;

@end


@implementation OBASearchResultsMapViewController

@synthesize appContext = _appContext;
@synthesize mapView = _mapView;
@synthesize currentLocationButton = _currentLocationButton;
@synthesize filterToolbar = _filterToolbar;

- (id)init {
    self = [super initWithNibName:@"OBASearchResultsMapViewController" bundle:nil];
    
    if (self)
    {
        self.title = NSLocalizedString(@"Map", @"Map tab title");
        self.tabBarItem.image = [UIImage imageNamed:@"Crosshairs"];
    }
    return self;
}

- (void) dealloc {
    [_searchController cancelOpenConnections];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    _networkErrorAlertViewDelegate = [[OBANetworkErrorAlertViewDelegate alloc] initWithContext:_appContext];

    CGRect indicatorBounds = CGRectMake(12, 12, 36, 36);
    self.activityIndicatorWrapper = [[UIView alloc] initWithFrame:indicatorBounds];
    self.activityIndicatorWrapper.backgroundColor = OBARGBACOLOR(0, 0, 0, 0.5);
    self.activityIndicatorWrapper.layer.cornerRadius = 4.f;
    self.activityIndicatorWrapper.layer.shouldRasterize = YES;
    self.activityIndicatorWrapper.layer.rasterizationScale = [UIScreen mainScreen].scale;
    self.activityIndicatorWrapper.hidden = YES;

    self.activityIndicatorView = [[UIActivityIndicatorView alloc] initWithFrame:CGRectInset(self.activityIndicatorWrapper.bounds, 4, 4)];
    self.activityIndicatorView.activityIndicatorViewStyle = UIActivityIndicatorViewStyleWhite;
    [self.activityIndicatorWrapper addSubview:self.activityIndicatorView];
    [self.view addSubview:self.activityIndicatorWrapper];

    CLLocationCoordinate2D p = {0,0};
    _mostRecentRegion = MKCoordinateRegionMake(p, MKCoordinateSpanMake(0,0));
    
    _refreshTimer = nil;
    
    _mapRegionManager = [[OBAMapRegionManager alloc] initWithMapView:_mapView];
    _mapRegionManager.lastRegionChangeWasProgramatic = YES;
    
    _hideFutureNetworkErrors = NO;
    
    self.filterToolbar = [[OBASearchResultsMapFilterToolbar alloc] initWithDelegate:self andAppContext:self.appContext];
    
    _searchController = [[OBASearchController alloc] initWithAppContext:_appContext];
    _searchController.delegate = self;
    _searchController.progress.delegate = self;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"lbs_arrow"] style:UIBarButtonItemStyleBordered target:self action:@selector(onCrossHairsButton:)];

    self.listBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"lines"] style:UIBarButtonItemStyleBordered target:self action:@selector(showListView:)];
    self.navigationItem.rightBarButtonItem = self.listBarButtonItem;
    self.navigationItem.titleView = self.searchBar;

    self.mapLabel.hidden = YES;
    self.mapLabel.alpha = 0;

    CALayer *labelLayer = self.mapLabel.layer;
    labelLayer.rasterizationScale = [UIScreen mainScreen].scale;
    labelLayer.shouldRasterize = YES;
    labelLayer.backgroundColor = [UIColor whiteColor].CGColor;
    labelLayer.opacity = 0.8;
    labelLayer.cornerRadius = 7;

    labelLayer.shadowColor = [UIColor blackColor].CGColor;
    labelLayer.shadowOpacity = 0.2;
    labelLayer.shadowOffset = CGSizeMake(0,0);
    labelLayer.shadowRadius = 7;
}

- (void)onFilterClear {
    [self.filterToolbar hideWithAnimated:YES];
    [self refreshStopsInRegion];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    self.navigationItem.title = NSLocalizedString(@"Map",@"self.navigationItem.title");
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didCompleteNetworkRequest) name:OBAApplicationDidCompleteNetworkRequestNotification object:nil];
    
    OBALocationManager * lm = _appContext.locationManager;
    [lm addDelegate:self];
    [lm startUpdatingLocation];
    _currentLocationButton.enabled = lm.locationServicesEnabled;
    
    if (_searchController.searchType == OBASearchTypeNone ) {
        _mapRegionManager.lastRegionChangeWasProgramatic = YES;
        CLLocation* location = lm.currentLocation;
        if (location) {
            [self locationManager:lm didUpdateLocation:location];
        }
    }
    
    [self refreshSearchToolbar];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OBAApplicationDidCompleteNetworkRequestNotification object:nil];
    
    [_appContext.locationManager stopUpdatingLocation];
    [_appContext.locationManager removeDelegate:self];

    [self.filterToolbar hideWithAnimated:NO];
}

#pragma mark - UISearchBarDelegate

- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar
{
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItem = nil;
    searchBar.showsCancelButton = YES;
    [self animateInScopeView];
    
    return YES;
}

- (BOOL)searchBarShouldEndEditing:(UISearchBar *)searchBar
{
    self.navigationItem.rightBarButtonItem = self.listBarButtonItem;
    searchBar.showsCancelButton = NO;
    [self animateOutScopeView];
    
    return YES;
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    [searchBar endEditing:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    OBANavigationTarget* target = nil;
    
    switch (self.searchTypeSegmentedControl.selectedSegmentIndex) {
        case kRouteSegmentIndex: {
            target = [OBASearch getNavigationTargetForSearchRoute:searchBar.text];
            break;
        }
        case kAddressSegmentIndex: {
            target = [OBASearch getNavigationTargetForSearchAddress:searchBar.text];
            break;
        }
        case kStopNumberSegmentIndex: {
            target = [OBASearch getNavigationTargetForSearchStopCode:searchBar.text];
            break;
        }
    }
    
    [_appContext navigateToTarget:target];
    
    [searchBar endEditing:YES];
}

- (void)animateInScopeView {
    CGRect offscreenScopeFrame = self.scopeView.frame;
    offscreenScopeFrame.origin.y = -offscreenScopeFrame.size.height;
    self.scopeView.frame = offscreenScopeFrame;
    [self.view addSubview:self.scopeView];
    
    CGRect finalScopeFrame = self.scopeView.frame;
    finalScopeFrame.origin.y = 0;
    
    [UIView animateWithDuration:kScopeViewAnimationDuration animations:^{
        self.scopeView.frame = finalScopeFrame;
    }];
}

- (void)animateOutScopeView {
    CGRect offscreenScopeFrame = self.scopeView.frame;
    offscreenScopeFrame.origin.y = -offscreenScopeFrame.size.height;
    
    [UIView animateWithDuration:kScopeViewAnimationDuration animations:^{
        self.scopeView.frame = offscreenScopeFrame;
    } completion:^(BOOL finished) {
        [self.scopeView removeFromSuperview];
    }];
}

#pragma mark - OBANavigationTargetAware

- (OBANavigationTarget*) navigationTarget {
    if( _searchController.searchType == OBASearchTypeRegion )
        return [OBASearch getNavigationTargetForSearchLocationRegion:_mapView.region];
    else
        return [_searchController getSearchTarget];
}

-(void) setNavigationTarget:(OBANavigationTarget*)target {
    
    OBASearchType searchType =  [OBASearch getSearchTypeForNagivationTarget:target];

    if( searchType == OBASearchTypeRegion ) {
        
        [_searchController searchPending];
        
        NSDictionary * parameters = target.parameters;
        NSData * data = parameters[kOBASearchControllerSearchArgumentParameter];
        MKCoordinateRegion region;
        [data getBytes:&region];
        [_mapRegionManager setRegion:region changeWasProgramatic:NO];
    }
    else {
        [_searchController searchWithTarget:target];
    }
    
    
    [self refreshSearchToolbar];
}

#pragma mark - OBASearchControllerDelegate Methods

- (void) handleSearchControllerStarted:(OBASearchType)searchType {
    if( ! (searchType == OBASearchTypeNone || searchType == OBASearchTypeRegion) ) {
        _mapRegionManager.lastRegionChangeWasProgramatic = NO;
    }    
}

- (void) handleSearchControllerUpdate:(OBASearchResult*)result {
    self.navigationItem.title = NSLocalizedString(@"Map",@"self.navigationItem.title");
    [self reloadData];
}

- (void) handleSearchControllerError:(NSError*)error {

    NSString * domain = [error domain];
    
    // We get this message because the user clicked "Don't allow" on using the current location.  Unfortunately,
    // this error gets propagated to us when the app isn't active (because the alert asking about location is).
    
    if( domain == kCLErrorDomain && [error code] == kCLErrorDenied ) {
        [self showLocationServicesAlert];
        return;
    }
    
    if( ! [self controllerIsVisibleAndActive] )
        return;
    
    if( [domain isEqual:NSURLErrorDomain] || [domain isEqual:NSPOSIXErrorDomain] ) {
        
        // We hide repeated network errors
        if( _hideFutureNetworkErrors )
            return;
        
        _hideFutureNetworkErrors = YES;
        self.navigationItem.title = NSLocalizedString(@"Error connecting",@"self.navigationItem.title");
        
        UIAlertView * view = [[UIAlertView alloc] init];
        view.title = NSLocalizedString(@"Error connecting",@"self.navigationItem.title");
        view.message = NSLocalizedString(@"There was a problem with your Internet connection.\n\nPlease check your network connection or contact us if you think the problem is on our end.",@"view.message");
        view.delegate = _networkErrorAlertViewDelegate;
        [view addButtonWithTitle:NSLocalizedString(@"Contact Us",@"view addButtonWithTitle")];
        [view addButtonWithTitle:NSLocalizedString(@"Dismiss",@"view addButtonWithTitle")];
        view.cancelButtonIndex = 1;
        [view show];
    }
}

#pragma mark - OBALocationManagerDelegate Methods

- (void) locationManager:(OBALocationManager *)manager didUpdateLocation:(CLLocation *)location {
    _currentLocationButton.enabled = YES;
    [self refreshCurrentLocation];
}

- (void) locationManager:(OBALocationManager *)manager didFailWithError:(NSError*)error {
    if( [error domain] == kCLErrorDomain && [error code] == kCLErrorDenied ) {
        [self showLocationServicesAlert];
    }
}

#pragma mark - OBAProgressIndicatorDelegate

- (void) progressUpdated {
    
    id<OBAProgressIndicatorSource> progress = _searchController.progress;

    if( progress.inProgress ) {
        self.activityIndicatorWrapper.hidden = NO;
        [self.activityIndicatorView startAnimating];
    }
    else {
        self.activityIndicatorWrapper.hidden = YES;
        [self.activityIndicatorView stopAnimating];
    }
}

#pragma mark MKMapViewDelegate Methods

- (void) mapView:(MKMapView *)aMapView didAddAnnotationViews:(NSArray *)views {
    for (MKAnnotationView *view in views) {
        if ([view.annotation isKindOfClass:[MKUserLocation class]]) {
            [view.superview bringSubviewToFront:view];
            return;
        }
    }
}

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    [_mapRegionManager mapView:mapView regionWillChangeAnimated:animated];
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {

    if (mapView.userLocation) {
        UIView *annotationView = [mapView viewForAnnotation:mapView.userLocation];
        [annotationView.superview bringSubviewToFront:annotationView];
    }
    
    BOOL applyingPendingRegionChangeRequest = [_mapRegionManager mapView:mapView regionDidChangeAnimated:animated];
    
    const OBASearchType searchType = _searchController.searchType;
    const BOOL unfilteredSearch = searchType == OBASearchTypeNone || searchType == OBASearchTypePending || searchType == OBASearchTypeRegion || searchType == OBASearchTypePlacemark;

    if (!applyingPendingRegionChangeRequest && unfilteredSearch) {
        if( _mapRegionManager.lastRegionChangeWasProgramatic ) {
            OBALocationManager * lm = _appContext.locationManager;
            double refreshInterval = [self getRefreshIntervalForLocationAccuracy:lm.currentLocation];
            [self scheduleRefreshOfStopsInRegion:refreshInterval location:lm.currentLocation];
        }
        else {
            [self scheduleRefreshOfStopsInRegion:kStopsInRegionRefreshDelayOnDrag location:nil];
        }
    }
    
    float scale = 1.0;
    float alpha = 1.0;
    
    OBASearchResult * result = _searchController.result;
    
    if( result && result.searchType == OBASearchTypeRouteStops ) {
        scale = [OBAPresentation computeStopsForRouteAnnotationScaleFactor:mapView.region];
        alpha = scale <= 0.11 ? 0.0 : 1.0;
    }
    
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    
    for( id<MKAnnotation> annotation in mapView.annotations ) {
        if ([annotation isKindOfClass:[OBAStopV2 class]]) {
            MKAnnotationView * view = [mapView viewForAnnotation:annotation];
            view.transform = transform;
            view.alpha = alpha;
        }
    }
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {

    if( [annotation isKindOfClass:[OBAStopV2 class]] ) {
        
        OBAStopV2 * stop = (OBAStopV2*)annotation;
        static NSString * viewId = @"StopView";
        
        MKAnnotationView * view = [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
        if( view == nil ) {
            view = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
        }
        view.canShowCallout = YES;
        view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        
        OBASearchResult * result = _searchController.result;
        
        if( result && result.searchType == OBASearchTypeRouteStops ) {
            float scale = [OBAPresentation computeStopsForRouteAnnotationScaleFactor:mapView.region];
            float alpha = scale <= 0.11 ? 0.0 : 1.0;
            
            view.transform = CGAffineTransformMakeScale(scale, scale);
            view.alpha = alpha;
        }

        OBAStopIconFactory * stopIconFactory = _appContext.stopIconFactory;
        view.image = [stopIconFactory getIconForStop:stop];
        return view;
    }
    else if( [annotation isKindOfClass:[OBAPlacemark class]] ) {
        static NSString * viewId = @"NavigationTargetView";
        MKPinAnnotationView * view = (MKPinAnnotationView*) [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
        if( view == nil ) {
            view = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
        }
        
        view.canShowCallout = YES;

        if( _searchController.searchType == OBASearchTypeAddress)
            view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        else
            view.rightCalloutAccessoryView = nil;
        return view;
    }
    else if( [annotation isKindOfClass:[OBANavigationTargetAnnotation class]] ) {
        static NSString * viewId = @"NavigationTargetView";
        MKPinAnnotationView * view = (MKPinAnnotationView*) [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
        if( view == nil ) {
            view = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
        }
        
        OBANavigationTargetAnnotation * nav = annotation;
        
        view.canShowCallout = YES;
        
        if( nav.target )
            view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        else
            view.rightCalloutAccessoryView = nil;
        
        return view;
    }
    else if( [annotation isKindOfClass:[OBAGenericAnnotation class]] ) {
        
        OBAGenericAnnotation * ga = annotation;
        if( [@"currentLocation" isEqual:ga.context] ) {
            static NSString * viewId = @"CurrentLocationView";
            
            MKAnnotationView * view = [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
            if( view == nil ) {
                view = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
            }
            view.canShowCallout = NO;
            view.image = [UIImage imageNamed:@"BlueMarker.png"];
            return view;
        }
    }
    
    return nil;
}

- (void) mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
    
    id annotation = view.annotation;
    
    if ([annotation isKindOfClass:[OBAStopV2 class]]) {
        OBAStopV2 * stop = annotation;
        OBAStopViewController * vc = [[OBAStopViewController alloc] initWithApplicationContext:_appContext stopId:stop.stopId];
        [self.navigationController pushViewController:vc animated:YES];
    }
    else if( [annotation isKindOfClass:[OBAPlacemark class]] ) {
        OBAPlacemark * placemark = annotation;
        OBANavigationTarget * target = [OBASearch getNavigationTargetForSearchPlacemark:placemark];
        [_searchController searchWithTarget:target];
    }
}

- (MKOverlayView *)mapView:(MKMapView *)mapView viewForOverlay:(id )overlay {    
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineView * polylineView  = [[MKPolylineView alloc] initWithPolyline:overlay];
        polylineView.fillColor = [UIColor blackColor];
        polylineView.strokeColor = [UIColor blackColor];
        polylineView.lineWidth = 5;
        return polylineView;
    }
    else {
        return nil;
    }
}

#pragma mark - UIAlertViewDelegate Methods

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if( buttonIndex == 0 ) {
        OBANavigationTarget * target = [OBASearch getNavigationTargetForSearchAgenciesWithCoverage];
        [_appContext navigateToTarget:target];
    }
}

#pragma mark - IBActions

- (void)showInfoPane {

}

- (IBAction)onCrossHairsButton:(id)sender {
    OBALogDebug(@"setting auto center on current location");
    _mapRegionManager.lastRegionChangeWasProgramatic = YES;
    [self refreshCurrentLocation];
}


- (IBAction)showListView:(id)sender {

    OBASearchResult * result = _searchController.result;

    if (result) {
        // Prune down the results to show only what's currently in the map view
        result = [result resultsInRegion:_mapView.region];
    }

    OBASearchResultsListViewController *listViewController = [[OBASearchResultsListViewController alloc]initWithContext:self.appContext searchControllerResult:result];
    listViewController.isModal = YES;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:listViewController];
    nav.modalTransitionStyle = UIModalTransitionStyleFlipHorizontal;
    [self presentViewController:nav animated:YES completion:nil];
}

@end


#pragma mark - OBASearchMapViewController Private Methods

@implementation OBASearchResultsMapViewController (Private)

- (void) refreshCurrentLocation {
    
    OBALocationManager * lm = _appContext.locationManager;
    CLLocation * location = lm.currentLocation;

    if( location ) {
        OBALogDebug(@"refreshCurrentLocation: auto center on current location: %d", _mapRegionManager.lastRegionChangeWasProgramatic);
        
        if( _mapRegionManager.lastRegionChangeWasProgramatic ) {
            double radius = MAX(location.horizontalAccuracy,kMinMapRadius);
            MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:location.coordinate latRadius:radius lonRadius:radius];
            [_mapRegionManager setRegion:region changeWasProgramatic:YES];
        }        
    }
}

- (void) scheduleRefreshOfStopsInRegion:(NSTimeInterval)interval location:(CLLocation*)location {
    
    MKCoordinateRegion region = _mapView.region;
    
    BOOL moreAccurateRegion = _mostRecentLocation != nil && location != nil && location.horizontalAccuracy < _mostRecentLocation.horizontalAccuracy;
    BOOL containedRegion = [OBASphericalGeometryLibrary isRegion:region containedBy:_mostRecentRegion];
    
    OBALogDebug(@"scheduleRefreshOfStopsInRegion: %f %d %d", interval, moreAccurateRegion, containedRegion);
    if( ! moreAccurateRegion && containedRegion )
        return;
    
    _mostRecentLocation = [NSObject releaseOld:_mostRecentLocation retainNew:location];
    
    if( _refreshTimer ) { 
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
    
     _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(refreshStopsInRegion) userInfo:nil repeats:NO];
}
               
- (NSTimeInterval) getRefreshIntervalForLocationAccuracy:(CLLocation*)location {
    if( location == nil )
        return kStopsInRegionRefreshDelayOnDrag;
    if( location.horizontalAccuracy < 20 )
        return 0;
    if( location.horizontalAccuracy < 200 )
        return 0.25;
    if( location.horizontalAccuracy < 500 )
        return 0.5;
    if( location.horizontalAccuracy < 1000 )
        return 1;
    return 1.5;
}

- (void) refreshStopsInRegion {
    _refreshTimer = nil;
    
    MKCoordinateRegion region = _mapView.region;
    MKCoordinateSpan   span   = region.span;

    if(span.latitudeDelta > kMaxLatDeltaToShowStops) {
        // Reset the most recent region
        CLLocationCoordinate2D p = {0,0};
        _mostRecentRegion = MKCoordinateRegionMake(p, MKCoordinateSpanMake(0,0));
        
        OBANavigationTarget * target = [OBASearch getNavigationTargetForSearchNone];
        [_searchController searchWithTarget:target];
    } else {
        span.latitudeDelta  *= kRegionScaleFactor;
        span.longitudeDelta *= kRegionScaleFactor;
        region.span = span;
    
        _mostRecentRegion = region;
    
        OBANavigationTarget * target = [OBASearch getNavigationTargetForSearchLocationRegion:region];
        [_searchController searchWithTarget:target];
    }
}

- (void) refreshSearchToolbar {
    // show the UIToolbar at the bottom of the view controller
    //
    UINavigationController * navController = self.navigationController;
    NSString * searchFilterDesc = [self computeSearchFilterString];
    if (searchFilterDesc != nil && navController.visibleViewController == self)
        [self.filterToolbar showWithDescription:searchFilterDesc animated:NO];
    else {
        [self.filterToolbar hideWithAnimated:YES];
    }

}

- (void) reloadData {
    OBASearchResult * result = _searchController.result;
    self.navigationItem.rightBarButtonItem.enabled = result != nil;
    
    if( result && result.searchType == OBASearchTypeRoute && [result.values count] > 0) {
        [self performSelector:@selector(showListView:) withObject:self afterDelay:1];
        return;
    }
    
    //[self refreshCurrentLocation];
    [self setAnnotationsFromResults];
    [self setOverlaysFromResults];
    [self setRegionFromResults];
    
    NSString * label = [self computeLabelForCurrentResults];
    [self applyMapLabelWithText:label];

    [self refreshSearchToolbar];
    [self checkResults];
}

- (void) applyMapLabelWithText:(NSString*)labelText {
    if (labelText && self.mapLabel.hidden) {
        self.mapLabel.text = labelText;
        self.mapLabel.alpha = 0.f;
        self.mapLabel.hidden = NO;
        [UIView animateWithDuration:kMapLabelAnimationDuration animations:^{
            self.mapLabel.alpha = 1.f;
        }];
    }
    else if (!labelText) {
        [UIView animateWithDuration:kMapLabelAnimationDuration animations:^{
            self.mapLabel.alpha = 0;
        } completion:^(BOOL finished) {
            self.mapLabel.hidden = YES;
        }];
    }
}

- (CLLocation*) currentLocation {
    if (_appContext.locationManager.currentLocation) {
        return _appContext.locationManager.currentLocation;
    }
    else if (_searchController.searchLocation) {
        return _searchController.searchLocation;
    }
    else {
        return [[CLLocation alloc] initWithLatitude:_mapView.centerCoordinate.latitude longitude:_mapView.centerCoordinate.longitude];
    }
}

- (void) showLocationServicesAlert {

    _currentLocationButton.enabled = NO;
    
    if (! [_appContext.modelDao hideFutureLocationWarnings]) {
        [_appContext.modelDao setHideFutureLocationWarnings:YES];
        
        UIAlertView * view = [[UIAlertView alloc] init];
        view.title = NSLocalizedString(@"Location Services Disabled",@"view.title");
        view.message = NSLocalizedString(@"Location Services are disabled for this app.  Some location-aware functionality will be missing.",@"view.message");
        [view addButtonWithTitle:NSLocalizedString(@"Dismiss",@"view addButtonWithTitle")];
        view.cancelButtonIndex = 0;
        [view show];
    }        
}

- (void) didCompleteNetworkRequest {
    _hideFutureNetworkErrors = NO;
}

- (void) setAnnotationsFromResults {
    NSMutableArray * annotations = [[NSMutableArray alloc] init];
    
    OBASearchResult * result = _searchController.result;
    
    if( result ) {
        [annotations addObjectsFromArray:result.values];

        if( result.searchType == OBASearchTypeAgenciesWithCoverage ) {           
            for( OBAAgencyWithCoverageV2 * agencyWithCoverage in result.values ) {
                OBAAgencyV2 * agency = agencyWithCoverage.agency;
                OBANavigationTargetAnnotation * an = [[OBANavigationTargetAnnotation alloc] initWithTitle:agency.name subtitle:nil coordinate:agencyWithCoverage.coordinate target:nil];
                [annotations addObject:an];
            }
        }
    }

    NSMutableArray * toAdd = [[NSMutableArray alloc] init];
    NSMutableArray * toRemove = [[NSMutableArray alloc] init];
    
    for( id annotation in [_mapView annotations] ) {
        if( ! [annotations containsObject:annotation] )
            [toRemove addObject:annotation];
    }
    
    for( id annotation in annotations ) {
        if( ! [[_mapView annotations] containsObject:annotation] )
            [toAdd addObject:annotation];
    }
    
    OBALogDebug(@"Annotations to remove: %d",[toRemove count]);
    OBALogDebug(@"Annotations to add: %d", [toAdd count]);
    
    [_mapView removeAnnotations:toRemove];
    [_mapView addAnnotations:toAdd];
    
}

- (void) setOverlaysFromResults {
    [_mapView removeOverlays:_mapView.overlays];

    OBASearchResult * result = _searchController.result;
    
    if( result && result.searchType == OBASearchTypeRouteStops) {
        for( NSString * polylineString in result.additionalValues ) {
            MKPolyline * polyline = [OBASphericalGeometryLibrary decodePolylineStringAsMKPolyline:polylineString];
            [_mapView  addOverlay:polyline];
        }
    }
}

- (NSString*) computeSearchFilterString {

    OBASearchType type = _searchController.searchType;
    id param = _searchController.searchParameter;

    switch(type) {
        case OBASearchTypeRoute:
            return [NSString stringWithFormat:@"%@ %@", NSLocalizedString(@"Route",@"route"), param];    
        case OBASearchTypeRouteStops: {
            OBARouteV2 * route = [_appContext.references getRouteForId:param];
            if( route )
                return [NSString stringWithFormat:@"%@ %@",NSLocalizedString(@"Route",@"route") , [route safeShortName]];
            return NSLocalizedString(@"Route",@"route");
        }
        case OBASearchTypeStopId:
            return [NSString stringWithFormat:@"%@ # %@",NSLocalizedString(@"Stop",@"OBASearchTypeStopId") , param];    
        case OBASearchTypeAgenciesWithCoverage:
            return NSLocalizedString(@"Transit Agencies",@"OBASearchTypeAgenciesWithCoverage");
        case OBASearchTypeAddress:
            return param;
        case OBASearchTypeNone:            
        case OBASearchTypeRegion:
        case OBASearchTypePlacemark:
        case OBASearchTypePending:
        default:
            return nil;
    }
    
    return nil;
}

- (NSString*) computeLabelForCurrentResults {
    OBASearchResult * result = _searchController.result;
    
    MKCoordinateRegion region = _mapView.region;
    MKCoordinateSpan span = region.span;
    
    NSString * defaultLabel = nil;
    if( span.latitudeDelta > kMaxLatDeltaToShowStops )
        defaultLabel = NSLocalizedString(@"Zoom in to look for stops.",@"span.latitudeDelta > kMaxLatDeltaToShowStops");
    
    if( !result )
        return defaultLabel;

    switch( result.searchType ) {
        case OBASearchTypeRoute:
        case OBASearchTypeRouteStops:    
        case OBASearchTypeAddress:
        case OBASearchTypeAgenciesWithCoverage:
        case OBASearchTypeStopId:
            return nil;
            
        case OBASearchTypePlacemark:
        case OBASearchTypeRegion: {
            if( result.outOfRange )
                return NSLocalizedString(@"Out of OneBusAway service area.",@"result.outOfRange");
            if( result.limitExceeded )
                return NSLocalizedString(@"Too many stops.  Zoom in for more detail.",@"result.limitExceeded");
            NSArray * values = result.values;
            if( [values count] == 0 )
                return NSLocalizedString(@"No stops at your current location.",@"[values count] == 0");
            return defaultLabel;
        }

        case OBASearchTypePending:
        case OBASearchTypeNone:
            return defaultLabel;
    }
}


- (void) setRegionFromResults {
    
    BOOL needsUpdate = NO;
    MKCoordinateRegion region = [self computeRegionForCurrentResults:&needsUpdate];
    if( needsUpdate ) {
        OBALogDebug(@"setRegionFromResults");
        [_mapRegionManager setRegion:region changeWasProgramatic:NO];
    }
}


- (MKCoordinateRegion) computeRegionForCurrentResults:(BOOL*)needsUpdate {
    
    *needsUpdate = YES;
    
    OBASearchResult *result = _searchController.result;
    
    if (!result ) {
        *needsUpdate = NO;
        return _mapView.region;
    }
    
    switch (result.searchType) {
        case OBASearchTypeStopId:
            return [self computeRegionForNClosestStops:result.values center:[self currentLocation] numberOfStops:kShowNClosestStops];
        case OBASearchTypeRoute:
        case OBASearchTypeRouteStops:    
            return [self computeRegionForNearbyStops:result.values];
        case OBASearchTypePlacemark:
            return [self computeRegionForPlacemarks:result.additionalValues andStops:result.values];
        case OBASearchTypeAddress:
            return [self computeRegionForPlacemarks:result.values];
        case OBASearchTypeAgenciesWithCoverage:
            return [self computeRegionForAgenciesWithCoverage:result.values];
        case OBASearchTypeNone:
        case OBASearchTypeRegion:
        default:
            *needsUpdate = NO;
            return _mapView.region;
    }
}

- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops {
    double latRun = 0.0, lonRun = 0.0;
    int    stopCount = 0;
    
    for( OBAStop * stop in stops ) {
        latRun += stop.lat;
        lonRun += stop.lon;
        ++stopCount;
    }

    CLLocation * centerLocation = nil;
    
    if (stopCount == 0) {
        centerLocation = self.currentLocation;
    } else {
        CLLocationCoordinate2D center;
        center.latitude  = latRun / stopCount;
        center.longitude = lonRun / stopCount;
        
        centerLocation = [[CLLocation alloc] initWithLatitude:center.latitude longitude:center.longitude];
    }
    
    return [self computeRegionForStops:stops center:centerLocation];
}

NSInteger sortStopsByDistanceFromLocation(id o1, id o2, void *context) {
    
    OBAStop * stop1 = (OBAStop*) o1;
    OBAStop * stop2 = (OBAStop*) o2;
    CLLocation * location = (__bridge CLLocation*)context;
    
    CLLocation * stopLocation1 = [[CLLocation alloc] initWithLatitude:stop1.lat longitude:stop1.lon];
    CLLocation * stopLocation2 = [[CLLocation alloc] initWithLatitude:stop2.lat longitude:stop2.lon];
    
    CLLocationDistance v1 = [location distanceFromLocation:stopLocation1];
    CLLocationDistance v2 = [location distanceFromLocation:stopLocation2];

    if (v1 < v2)
        return NSOrderedAscending;
    else if (v1 > v2)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

- (MKCoordinateRegion) computeRegionForNClosestStops:(NSArray*)stops center:(CLLocation*)location numberOfStops:(NSUInteger)numberOfStops {
    NSMutableArray * stopsSortedByDistance = [NSMutableArray arrayWithArray:stops];
    [stopsSortedByDistance sortUsingFunction:sortStopsByDistanceFromLocation context:(__bridge void *)(location)];
    while( [stopsSortedByDistance count] > numberOfStops )
        [stopsSortedByDistance removeLastObject];
    return [self computeRegionForStops:stopsSortedByDistance center:location];
}

- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops center:(CLLocation*)location {
    
    CLLocationCoordinate2D center = location.coordinate;
    
    MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:center latRadius:kDefaultMapRadius lonRadius:kDefaultMapRadius];
    MKCoordinateSpan span = region.span;
    
    for( OBAStop * stop in stops ) {
        double latDelta = ABS(stop.lat - center.latitude) * 2.0 * kPaddingScaleFactor;
        double lonDelta = ABS(stop.lon - center.longitude) * 2.0 * kPaddingScaleFactor;
        
        span.latitudeDelta  = MAX(span.latitudeDelta,latDelta);
        span.longitudeDelta = MAX(span.longitudeDelta,lonDelta);
    }
    
    region.center = center;
    region.span = span;
    
    return region;
}

- (MKCoordinateRegion) computeRegionForNearbyStops:(NSArray*)stops {
    
    NSMutableArray * stopsInRange = [NSMutableArray array];
    CLLocation * center = [self currentLocation];
    
    for( OBAStop * stop in stops) {
        CLLocation * location = [[CLLocation alloc] initWithLatitude:stop.lat longitude:stop.lon];
        CLLocationDistance d = [location distanceFromLocation:center];
        if( d < kMaxMapDistanceFromCurrentLocationForNearby )
            [stopsInRange addObject:stop];
    }
    
    if( [stopsInRange count] > 0)
        return [self computeRegionForStops:stopsInRange center:center];
    else
        return [self computeRegionForStops:stops];
}

- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks {
    
    OBACoordinateBounds * bounds = [OBACoordinateBounds bounds];
    
    for( OBAPlacemark * placemark in placemarks )
        [bounds addCoordinate:placemark.coordinate];
    
    if( bounds.empty )
        return _mapView.region;
    
    return bounds.region;
}

- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks andStops:(NSArray*)stops {
    
    CLLocation * center = [self currentLocation];
    
    for( OBAPlacemark * placemark in placemarks ) {
        CLLocationCoordinate2D coordinate = placemark.coordinate;
        center = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    }
    
    return [self computeRegionForNClosestStops:stops center:center numberOfStops:kShowNClosestStops];
}

- (MKCoordinateRegion) computeRegionForAgenciesWithCoverage:(NSArray*)agenciesWithCoverage {
    if (0 == agenciesWithCoverage.count) {
        return _mapView.region;
    }
    
    OBACoordinateBounds * bounds = [OBACoordinateBounds bounds];
    
    for( OBAAgencyWithCoverage * agencyWithCoverage in agenciesWithCoverage )
        [bounds addCoordinate:agencyWithCoverage.coordinate];
    
    if( bounds.empty )
        return _mapView.region;
    
    MKCoordinateRegion region = bounds.region;
    
    MKCoordinateRegion minRegion = [OBASphericalGeometryLibrary createRegionWithCenter:region.center latRadius:50000 lonRadius:50000];
    
    if( region.span.latitudeDelta < minRegion.span.latitudeDelta )
        region.span.latitudeDelta = minRegion.span.latitudeDelta;
    
    if( region.span.longitudeDelta < minRegion.span.longitudeDelta )
        region.span.longitudeDelta = minRegion.span.longitudeDelta;
    
    return region;
}

- (MKCoordinateRegion) getLocationAsRegion:(CLLocation*)location {
    double radius = MAX(location.horizontalAccuracy,kMinMapRadius);
    MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:location.coordinate latRadius:radius lonRadius:radius];    
    region = [_mapView regionThatFits:region];
    return region;
}

- (void) checkResults {
    
    OBASearchResult * result = _searchController.result;
    if( ! result )
        return;
    
    switch (result.searchType) {
        case OBASearchTypeRegion:
        case OBASearchTypePlacemark:
            [self checkOutOfRangeResults];
            break;
        case OBASearchTypeRoute:            
            if( ! [self checkOutOfRangeResults] )
                [self checkNoRouteResults];
            break;
        case OBASearchTypeAddress:
            if( ! [self checkOutOfRangeResults] )
                [self checkNoPlacemarksResults];
            break;
        default:
            break;
    }
}

- (BOOL) checkOutOfRangeResults {
    OBASearchResult * result = _searchController.result;
    if( result.outOfRange )
        [self showNoResultsAlertWithTitle: NSLocalizedString(@"Out of range",@"showNoResultsAlertWithTitle") prompt:NSLocalizedString(@"You are outside the OneBusAway service area.",@"prompt")];
    return result.outOfRange;
}

- (void) checkNoRouteResults {
    OBASearchResult * result = _searchController.result;
    if( [result.values count] == 0 ) {
        [self showNoResultsAlertWithTitle: NSLocalizedString(@"No routes found",@"showNoResultsAlertWithTitle") prompt:NSLocalizedString(@"No routes were found for your search.",@"prompt")];
    }
}

- (void) checkNoPlacemarksResults {
    OBASearchResult * result = _searchController.result;
    if( [result.values count] == 0 ) {
        self.navigationItem.rightBarButtonItem.enabled = NO;
        [self showNoResultsAlertWithTitle: NSLocalizedString(@"No places found",@"showNoResultsAlertWithTitle") prompt:NSLocalizedString(@"No places were found for your search.",@"prompt")];
    }
}

- (void) showNoResultsAlertWithTitle:(NSString*)title prompt:(NSString*)prompt {

    self.navigationItem.rightBarButtonItem.enabled = NO;

    if( ! [self controllerIsVisibleAndActive] )
        return;
    
    UIAlertView * view = [[UIAlertView alloc] init];
    view.title = title;
    view.message = [NSString stringWithFormat:@"%@ %@",prompt,NSLocalizedString(@"See the list of supported transit agencies.",@"view.message")];
    view.delegate = self;
    [view addButtonWithTitle:NSLocalizedString(@"Agencies",@"OBASearchTypeAgenciesWithCoverage")];
    [view addButtonWithTitle:NSLocalizedString(@"Dismiss",@"view addButtonWithTitle")];
    view.cancelButtonIndex = 1;
    [view show];
}

- (BOOL) controllerIsVisibleAndActive {
    
    // Ignore errors if our app isn't currently active
    if( ! _appContext.active )
        return NO;
    
    // Ignore errors if our view isn't currently on top
    UINavigationController * nav = self.navigationController;
    if( self != [nav visibleViewController])
        return NO;
    
    return YES;
}    

@end


