#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <dispatch/dispatch.h>
#import <math.h>

static UIWindow *gNetSpeedWindow;
static UILabel *gNetSpeedLabel;
static dispatch_source_t gSampleTimer;
static dispatch_queue_t gSampleQueue;
static uint64_t gPreviousReceived;
static uint64_t gPreviousSent;
static uint64_t gPreviousTimestamp;
static double gSmoothedDownload;
static double gSmoothedUpload;

static uint64_t NetSpeedNow(void) {
	return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static void NetSpeedReadCounters(uint64_t *received, uint64_t *sent) {
	*received = 0;
	*sent = 0;

	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
		return;
	}

	NSMutableSet<NSString *> *countedInterfaces = [NSMutableSet set];
	for (struct ifaddrs *current = interfaces; current != NULL; current = current->ifa_next) {
		if (current->ifa_name == NULL || current->ifa_addr == NULL) {
			continue;
		}
		if ((current->ifa_flags & IFF_LOOPBACK) != 0 || current->ifa_data == NULL) {
			continue;
		}

		NSString *name = [NSString stringWithUTF8String:current->ifa_name];
		BOOL supported = [name isEqualToString:@"en0"] || [name hasPrefix:@"pdp_ip"];
		if (!supported) {
			continue;
		}
		// getifaddrs may return one record per address; count each interface once.
		if ([countedInterfaces containsObject:name]) {
			continue;
		}
		[countedInterfaces addObject:name];

		struct if_data *data = (struct if_data *)current->ifa_data;
		uint64_t interfaceReceived = (uint64_t)data->ifi_ibytes;
		uint64_t interfaceSent = (uint64_t)data->ifi_obytes;
		if (UINT64_MAX - *received < interfaceReceived) {
			*received = UINT64_MAX;
		} else {
			*received += interfaceReceived;
		}
		if (UINT64_MAX - *sent < interfaceSent) {
			*sent = UINT64_MAX;
		} else {
			*sent += interfaceSent;
		}
	}

	freeifaddrs(interfaces);
}

static NSString *NetSpeedFormat(double bytesPerSecond) {
	if (!isfinite(bytesPerSecond) || bytesPerSecond < 0.0) {
		bytesPerSecond = 0.0;
	}

	if (bytesPerSecond >= 1024.0 * 1024.0) {
		return [NSString stringWithFormat:@"%.1fM/s", bytesPerSecond / (1024.0 * 1024.0)];
	}
	if (bytesPerSecond >= 1024.0) {
		return [NSString stringWithFormat:@"%.1fK/s", bytesPerSecond / 1024.0];
	}
	return [NSString stringWithFormat:@"%.0fB/s", bytesPerSecond];
}

static void NetSpeedUpdateLayout(void) {
	if (gNetSpeedWindow == nil || gNetSpeedLabel == nil) {
		return;
	}

	UIWindowScene *scene = gNetSpeedWindow.windowScene;
	CGRect bounds = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
	UIEdgeInsets insets = scene ? scene.windows.firstObject.safeAreaInsets : UIEdgeInsetsZero;
	CGFloat top = MAX(insets.top, 20.0);
	CGFloat width = MIN(150.0, MAX(118.0, bounds.size.width * 0.34));
	CGFloat height = 20.0;
	CGFloat x = MAX(4.0, bounds.size.width - width - 8.0);

	gNetSpeedWindow.frame = bounds;
	gNetSpeedLabel.frame = CGRectMake(x, MAX(0.0, top - 2.0), width, height);
}

static void NetSpeedCreateWindow(void) {
	if (gNetSpeedWindow != nil) {
		NetSpeedUpdateLayout();
		return;
	}

	gNetSpeedWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
			gNetSpeedWindow.windowScene = (UIWindowScene *)scene;
			break;
		}
	}
	gNetSpeedWindow.windowLevel = UIWindowLevelStatusBar + 1.0;
	gNetSpeedWindow.backgroundColor = UIColor.clearColor;
	gNetSpeedWindow.userInteractionEnabled = NO;
	gNetSpeedWindow.opaque = NO;

	gNetSpeedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
	gNetSpeedLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightMedium];
	gNetSpeedLabel.textColor = UIColor.labelColor;
	gNetSpeedLabel.textAlignment = NSTextAlignmentRight;
	gNetSpeedLabel.adjustsFontSizeToFitWidth = YES;
	gNetSpeedLabel.minimumScaleFactor = 0.7;
	gNetSpeedLabel.text = @"↓ 0B/s  ↑ 0B/s";
	[gNetSpeedWindow addSubview:gNetSpeedLabel];

	[gNetSpeedWindow makeKeyAndVisible];
	[gNetSpeedWindow resignKeyWindow];
	NetSpeedUpdateLayout();

	[[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
	                                                  object:nil
	                                                   queue:[NSOperationQueue mainQueue]
	                                              usingBlock:^(__unused NSNotification *notification) {
		NetSpeedUpdateLayout();
	}];

}

static void NetSpeedStartSampling(void) {
	if (gSampleTimer != nil) {
		return;
	}

	gSampleQueue = dispatch_queue_create("com.example.netspeedstatus.sampling", DISPATCH_QUEUE_SERIAL);
	gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gSampleQueue);
	dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(gSampleTimer, ^{
		uint64_t received = 0;
		uint64_t sent = 0;
		uint64_t now = NetSpeedNow();
		NetSpeedReadCounters(&received, &sent);

		if (gPreviousTimestamp != 0 && now > gPreviousTimestamp && received >= gPreviousReceived && sent >= gPreviousSent) {
			double interval = (double)(now - gPreviousTimestamp) / 1000000000.0;
			double download = (double)(received - gPreviousReceived) / interval;
			double upload = (double)(sent - gPreviousSent) / interval;
			gSmoothedDownload = gSmoothedDownload == 0.0 ? download : gSmoothedDownload * 0.7 + download * 0.3;
			gSmoothedUpload = gSmoothedUpload == 0.0 ? upload : gSmoothedUpload * 0.7 + upload * 0.3;
		}

		gPreviousReceived = received;
		gPreviousSent = sent;
		gPreviousTimestamp = now;
		NSString *text = [NSString stringWithFormat:@"↓ %@  ↑ %@", NetSpeedFormat(gSmoothedDownload), NetSpeedFormat(gSmoothedUpload)];
		dispatch_async(dispatch_get_main_queue(), ^{
			gNetSpeedLabel.text = text;
		});
	});
	dispatch_resume(gSampleTimer);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		NetSpeedCreateWindow();
		NetSpeedStartSampling();
	});
}

%end
