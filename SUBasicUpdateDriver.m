//
//  SUBasicUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/23/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUBasicUpdateDriver.h"

#import "SUHost.h"
#import "SUDSAVerifier.h"
#import "SUInstaller.h"
#import "SUStandardVersionComparator.h"
#import "SUUnarchiver.h"
#import "SUConstants.h"
#import "SULog.h"
#import "SUPlainInstaller.h"
#import "SUPlainInstallerInternals.h"
#import "SUBinaryDeltaCommon.h"
#import "SUCodeSigningVerifier.h"
#import "SUUpdater_Private.h"
#import "SUXPC.h"

#ifdef FINISH_INSTALL_TOOL_NAME
// FINISH_INSTALL_TOOL_NAME expands to unquoted finish_install
#define QUOTE_NS_STRING2(str) @"" #str
#define QUOTE_NS_STRING1(str) QUOTE_NS_STRING2(str)
#define FINISH_INSTALL_TOOL_NAME_STRING QUOTE_NS_STRING1(FINISH_INSTALL_TOOL_NAME)
#else
#error FINISH_INSTALL_TOOL_NAME not defined
#endif


@interface SUBasicUpdateDriver () <NSURLDownloadDelegate>
@property (nonatomic, retain) SUAppcast *appcast;
@end


@implementation SUBasicUpdateDriver

- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)aHost
{
	[super checkForUpdatesAtURL:URL host:aHost];
	if ([aHost isRunningOnReadOnlyVolume])
	{
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURunningFromDiskImageError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"%1$@ can't be updated when it's running from a read-only volume like a disk image or an optical drive. Move %1$@ to your Applications folder, relaunch it from there, and try again.", nil), [aHost name]] forKey:NSLocalizedDescriptionKey]]];
		return;
	}
	
	self.appcast = [[[SUAppcast alloc] init] autorelease];
	SUAppcast *appcast = self.appcast;
	
	[appcast setUserAgentString:[updater userAgentString]];
	[appcast fetchAppcastFromURL:URL];
}

- (id <SUVersionComparison>)versionComparator
{
	id <SUVersionComparison> comparator = nil;
	
	// Give the delegate a chance to provide a custom version comparator
	if ([[updater delegate] respondsToSelector:@selector(versionComparatorForUpdater:)])
		comparator = [[updater delegate] versionComparatorForUpdater:updater];
	
	// If we don't get a comparator from the delegate, use the default comparator
	if (!comparator)
		comparator = [SUStandardVersionComparator defaultComparator];
	
	return comparator;
}

- (BOOL)isItemNewer:(SUAppcastItem *)ui
{
	return [[self versionComparator] compareVersion:[host version] toVersion:[ui versionString]] == NSOrderedAscending;
}

- (BOOL)hostSupportsItem:(SUAppcastItem *)ui
{
	if (([ui minimumSystemVersion] == nil || [[ui minimumSystemVersion] isEqualToString:@""]) &&
		([ui maximumSystemVersion] == nil || [[ui maximumSystemVersion] isEqualToString:@""])) { return YES; }
	
	BOOL minimumVersionOK = TRUE;
	BOOL maximumVersionOK = TRUE;
	
	// Check minimum and maximum System Version
	if ([ui minimumSystemVersion] != nil && ![[ui minimumSystemVersion] isEqualToString:@""]) {
		minimumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui minimumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedDescending;
	}
	if ([ui maximumSystemVersion] != nil && ![[ui maximumSystemVersion] isEqualToString:@""]) {
		maximumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui maximumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedAscending;
	}
	
	return minimumVersionOK && maximumVersionOK;
}

- (BOOL)itemContainsSkippedVersion:(SUAppcastItem *)ui
{
	NSString *skippedVersion = [host objectForUserDefaultsKey:SUSkippedVersionKey];
	if (skippedVersion == nil) { return NO; }
	return [[self versionComparator] compareVersion:[ui versionString] toVersion:skippedVersion] != NSOrderedDescending;
}

- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui
{
	return [self hostSupportsItem:ui] && [self isItemNewer:ui] && ![self itemContainsSkippedVersion:ui];
}

- (void)appcastDidFinishLoading:(SUAppcast *)ac
{
	if ([[updater delegate] respondsToSelector:@selector(updater:didFinishLoadingAppcast:)])
		[[updater delegate] updater:updater didFinishLoadingAppcast:ac];
	
	NSDictionary *userInfo = (ac != nil) ? @{SUUpdaterAppcastNotificationKey : ac} : nil;
	[[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidFinishLoadingAppCastNotification object:updater userInfo:userInfo];
	
	SUAppcastItem *item = nil;
	
	// Now we have to find the best valid update in the appcast.
	if ([[updater delegate] respondsToSelector:@selector(bestValidUpdateInAppcast:forUpdater:)]) // Does the delegate want to handle it?
	{
		item = [[updater delegate] bestValidUpdateInAppcast:ac forUpdater:updater];
	}
	else // If not, we'll take care of it ourselves.
	{
		// Find the first update we can actually use.
		NSArray *items = [ac items];
		
		SUStandardVersionComparator *versionComparator = [SUStandardVersionComparator defaultComparator];
		items = [items sortedArrayUsingComparator:^NSComparisonResult(SUAppcastItem *item1, SUAppcastItem *item2) {
			return [versionComparator compareVersion:item2.versionString toVersion:item1.versionString];
		}];
		
		NSEnumerator *updateEnumerator = [items objectEnumerator];
		do {
			item = [updateEnumerator nextObject];
		} while (item && ![self hostSupportsItem:item]);
		
		if (binaryDeltaSupported()) {
			SUAppcastItem *deltaUpdateItem = [[item deltaUpdates] objectForKey:[host version]];
			if (deltaUpdateItem && [self hostSupportsItem:deltaUpdateItem]) {
				nonDeltaUpdateItem = [item retain];
				item = deltaUpdateItem;
			}
		}
	}
	
	updateItem = [item retain];
	self.appcast = nil;
	if (updateItem == nil) { [self didNotFindUpdate]; return; }
	
	if ([self itemContainsValidUpdate:updateItem])
		[self didFindValidUpdate];
	else
		[self didNotFindUpdate];
}

- (void)appcast:(SUAppcast *)ac failedToLoadWithError:(NSError *)error
{
	self.appcast = nil;
	[self abortUpdateWithError:error];
}

- (void)didFindValidUpdate
{
	if ([[updater delegate] respondsToSelector:@selector(updater:didFindValidUpdate:)])
		[[updater delegate] updater:updater didFindValidUpdate:updateItem];
	NSDictionary *userInfo = (updateItem != nil) ? @{SUUpdaterAppcastItemNotificationKey : updateItem} : nil;
	[[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidFinishLoadingAppCastNotification object:updater userInfo:userInfo];
	[self downloadUpdate];
}

- (void)didNotFindUpdate
{
	if ([[updater delegate] respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[[updater delegate] updaterDidNotFindUpdate:updater];
	[[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidNotFindUpdateNotification object:updater];
	
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUNoUpdateError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"You already have the newest version of %@.", nil), [host name]] forKey:NSLocalizedDescriptionKey]]];
}

- (void)downloadUpdate
{
    // CLF: Clean up old downloads first to mitigate this issue: https://github.com/sparkle-project/Sparkle/issues/750
    NSString *oldFilesPath = [host appSupportPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:oldFilesPath]) {
        NSError *error;
        if (![[NSFileManager defaultManager] removeItemAtPath:oldFilesPath error:&error]) {
            NSLog(@"Error removing old .Sparkle directory: %@", error);
        }
    }
    
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[updateItem fileURL]];
	[request setValue:[updater userAgentString] forHTTPHeaderField:@"User-Agent"];
	download = [[NSURLDownload alloc] initWithRequest:request delegate:self];
}

- (void)download:(NSURLDownload *)d decideDestinationWithSuggestedFilename:(NSString *)name
{
	// If name ends in .txt, the server probably has a stupid MIME configuration. We'll give the developer the benefit of the doubt and chop that off.
	if ([[name pathExtension] isEqualToString:@"txt"])
		name = [name stringByDeletingPathExtension];
	
	NSString *downloadFileName = [NSString stringWithFormat:@"%@ %@", [host name], [updateItem versionString]];
	
	
	[tempDir release];
	tempDir = [[[host appSupportPath] stringByAppendingPathComponent:downloadFileName] retain];
	int cnt=1;
	while ([[NSFileManager defaultManager] fileExistsAtPath:tempDir] && cnt <= 999)
	{
		[tempDir release];
		tempDir = [[[host appSupportPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", downloadFileName, cnt++]] retain];
	}
	
	// Create the temporary directory if necessary.
	BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:NULL];
	if (!success)
	{
		// Okay, something's really broken with this user's file structure.
		[download cancel];
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUTemporaryDirectoryError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Can't make a temporary directory for the update download at %@.",tempDir] forKey:NSLocalizedDescriptionKey]]];
	}
	
	downloadPath = [[tempDir stringByAppendingPathComponent:name] retain];
	[download setDestination:downloadPath allowOverwrite:YES];
}

- (BOOL)validateUpdateDownloadedToPath:(NSString *)downloadedPath extractedToPath:(NSString *)extractedPath DSASignature:(NSString *)DSASignature publicDSAKey:(NSString *)publicDSAKey
{
    if (self.usesInstallerBasedInstallation) {
        // TODO: spend more time on this to get this check working, otherwise in the meantime we'll rely on macOS which will check that the installer is notarized and signed anyways
        return YES;
    }
    
    NSString *newBundlePath = [SUInstaller appPathInUpdateFolder:extractedPath forHost:host];
	if (newBundlePath)
	{
		NSError *error = nil;
		if ([SUCodeSigningVerifier codeSignatureIsValidAtPath:newBundlePath error:&error]) {
			return YES;
		} else {
			SULog(@"Code signature check on update failed: %@", error);
		}
	}
	
	return [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:publicDSAKey];
}

- (void)downloadDidFinish:(NSURLDownload *)d
{
	[self extractUpdate];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error
{
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while downloading the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (BOOL)download:(NSURLDownload *)download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType
{
	// We don't want the download system to extract our gzips.
	// Note that we use a substring matching here instead of direct comparison because the docs say "application/gzip" but the system *uses* "application/x-gzip". This is a documentation bug.
	return ([encodingType rangeOfString:@"gzip"].location == NSNotFound);
}

- (void)extractUpdate
{
	self.unarchiver = [SUUnarchiver unarchiverForPath:downloadPath updatingHost:host];
	SUUnarchiver *unarchiver = self.unarchiver;
	if (!unarchiver)
	{
		SULog(@"Sparkle Error: No valid unarchiver for %@!", downloadPath);
		[self unarchiverDidFail:nil];
		return;
	}
	[unarchiver start];
}

- (void)failedToApplyDeltaUpdate
{
	// When a delta update fails to apply we fall back on updating via a full install.
	[updateItem release];
	updateItem = nonDeltaUpdateItem;
	nonDeltaUpdateItem = nil;
	
	[self downloadUpdate];
}

- (void)unarchiverDidFinish:(SUUnarchiver *)ua
{
	self.unarchiver = nil;
	[self installWithToolAndRelaunch:YES];
}

- (void)unarchiverDidFail:(SUUnarchiver *)ua
{
	self.unarchiver = nil;
	
	if ([updateItem isDeltaUpdate]) {
		[self failedToApplyDeltaUpdate];
		return;
	}
	
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUUnarchivingError userInfo:[NSDictionary dictionaryWithObject:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil) forKey:NSLocalizedDescriptionKey]]];
}

- (BOOL)shouldInstallSynchronously { return NO; }

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
	// Perhaps a poor assumption but: if we're not relaunching, we assume we shouldn't be showing any UI either. Because non-relaunching installations are kicked off without any user interaction, we shouldn't be interrupting them.
	[self installWithToolAndRelaunch:relaunch displayingUserInterface:relaunch];
}

- (void)installWithToolAndRelaunch:(BOOL)relaunch displayingUserInterface:(BOOL)showUI
{
#if !ENDANGER_USERS_WITH_INSECURE_UPDATES
	if (![self validateUpdateDownloadedToPath:downloadPath extractedToPath:tempDir DSASignature:[updateItem DSASignature] publicDSAKey:[host publicDSAKey]])
	{
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUSignatureError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, @"The update is improperly signed.", NSLocalizedFailureReasonErrorKey, nil]]];
		return;
	}
#endif
	
	if (![updater mayUpdateAndRestart])
	{
		[self abortUpdate];
		return;
	}
	
	BOOL running10_7 = floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6;
	
	//	[MIK:Patrick Machielse] check for xpc service bundled with the host OR with MIKUpdate
	//	code is a bit clumsy, as 'bundles' may use different paths during debugging?
	//
	NSFileManager *fman = [NSFileManager defaultManager];
	BOOL hostXPC = [fman fileExistsAtPath:[[host bundlePath] stringByAppendingPathComponent:@"Contents/XPCServices/com.andymatuschak.Sparkle.SandboxService.xpc"]];
	BOOL updateXPC = [fman fileExistsAtPath:[[host bundlePath] stringByAppendingPathComponent:@"Contents/Frameworks/MIKUpdate.framework/XPCServices/com.andymatuschak.Sparkle.SandboxService.xpc"]];
	BOOL useXPC = running10_7 && (hostXPC || updateXPC);
	
	// Give the host app an opportunity to postpone the install and relaunch.
	static BOOL postponedOnce = NO;
	if (!postponedOnce && [[updater delegate] respondsToSelector:@selector(updater:shouldPostponeRelaunchForUpdate:untilInvoking:)])
	{
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(installWithToolAndRelaunch:)]];
		[invocation setSelector:@selector(installWithToolAndRelaunch:)];
		[invocation setArgument:&relaunch atIndex:2];
		[invocation setTarget:self];
		postponedOnce = YES;
		if ([[updater delegate] updater:updater shouldPostponeRelaunchForUpdate:updateItem untilInvoking:invocation])
			return;
	}
	
	
	if ([[updater delegate] respondsToSelector:@selector(updater:willInstallUpdate:)])
		[[updater delegate] updater:updater willInstallUpdate:updateItem];
	
	NSString *const finishInstallToolName = FINISH_INSTALL_TOOL_NAME_STRING;
	
	// Copy the relauncher into a temporary directory so we can get to it after the new version's installed.
	// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
	NSString *relaunchPathToCopy = [SPARKLE_BUNDLE pathForResource:finishInstallToolName ofType:@"app"];
	if (relaunchPathToCopy != nil)
	{
		NSString *targetPath = [[host appSupportPath] stringByAppendingPathComponent:[relaunchPathToCopy lastPathComponent]];
		// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
		NSError *error = nil;
		[[NSFileManager defaultManager] createDirectoryAtPath: [targetPath stringByDeletingLastPathComponent] withIntermediateDirectories: YES attributes: [NSDictionary dictionary] error: &error];
		
		// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
		BOOL copiedRelaunchTool = FALSE;
		if( useXPC )
			copiedRelaunchTool = [SUXPC copyPathWithAuthentication: relaunchPathToCopy overPath: targetPath temporaryName: nil error: &error];
		else
			copiedRelaunchTool = [SUPlainInstaller copyPathWithAuthentication: relaunchPathToCopy overPath: targetPath temporaryName: nil error: &error];
		if( copiedRelaunchTool )
			relaunchPath = [targetPath retain];
		else
			[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't copy relauncher (%@) to temporary path (%@)! %@", relaunchPathToCopy, targetPath, (error ? [error localizedDescription] : @"")], NSLocalizedFailureReasonErrorKey, nil]]];
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterWillRestartNotification object:self];
	if ([[updater delegate] respondsToSelector:@selector(updaterWillRelaunchApplication:)])
		[[updater delegate] updaterWillRelaunchApplication:updater];
	
	if(!relaunchPath || ![[NSFileManager defaultManager] fileExistsAtPath:relaunchPath])
	{
		// Note that we explicitly use the host app's name here, since updating plugin for Mail relaunches Mail, not just the plugin.
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:SULocalizedString(@"An error occurred while relaunching %1$@, but the new version will be available next time you run %1$@.", nil), [host name]], NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't find the relauncher (expected to find it at %@)", relaunchPath], NSLocalizedFailureReasonErrorKey, nil]]];
		// We intentionally don't abandon the update here so that the host won't initiate another.
		return;
	}
	
	NSString *pathToRelaunch = [host bundlePath];
	if ([[updater delegate] respondsToSelector:@selector(pathToRelaunchForUpdater:)])
		pathToRelaunch = [[updater delegate] pathToRelaunchForUpdater:updater];
	NSString *relaunchToolPath = [[relaunchPath stringByAppendingPathComponent: @"/Contents/MacOS"] stringByAppendingPathComponent: finishInstallToolName];
	NSArray *arguments = [NSArray arrayWithObjects:[host bundlePath], pathToRelaunch, [NSString stringWithFormat:@"%d", [[NSProcessInfo processInfo] processIdentifier]], tempDir, relaunch ? @"1" : @"0", showUI ? @"1" : @"0", nil];
	if( useXPC )
		[SUXPC launchTaskWithLaunchPath: relaunchToolPath arguments:arguments];
	else
		[NSTask launchedTaskWithLaunchPath: relaunchToolPath arguments:arguments];
	
	[NSApp terminate:self];
}

- (void)cleanUpDownload
{
	if (tempDir != nil)	// tempDir contains downloadPath, so we implicitly delete both here.
	{
		BOOL		success = NO;
		NSError	*	error = nil;
		success = [[NSFileManager defaultManager] removeItemAtPath: tempDir error: &error]; // Clean up the copied relauncher
		if( !success )
			[[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[tempDir stringByDeletingLastPathComponent] destination:@"" files:[NSArray arrayWithObject:[tempDir lastPathComponent]] tag:NULL];
	}
}

- (void)installerForHost:(SUHost *)aHost failedWithError:(NSError *)error
{
	if (aHost != host) { return; }
	NSError	*	dontThrow = nil;
	[[NSFileManager defaultManager] removeItemAtPath: relaunchPath error: &dontThrow]; // Clean up the copied relauncher
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while installing the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (void)abortUpdate
{
	self.appcast = nil;
	self.unarchiver = nil;

	[[self retain] autorelease];	// In case the notification center was the last one holding on to us.
	[self cleanUpDownload];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[super abortUpdate];
}

- (void)abortUpdateWithError:(NSError *)error
{
	if ([error code] != SUNoUpdateError) // Let's not bother logging this.
		SULog(@"Sparkle Error: %@", [error localizedDescription]);
	if ([error localizedFailureReason])
		SULog(@"Sparkle Error (continued): %@", [error localizedFailureReason]);
	[download cancel];
	
	if ([[updater delegate] respondsToSelector:@selector(updater:didEncounterError:)]) {
		[[updater delegate] updater:updater didEncounterError:error];
	}
	
	[self abortUpdate];
}

@synthesize appcast = _appcast;

- (void)setAppcast:(SUAppcast *)appcast
{
	if (_appcast != appcast) {
		if (_appcast.delegate == self) _appcast.delegate = nil;

		[_appcast release];
		_appcast = [appcast retain];

		_appcast.delegate = self;
	}
}

@synthesize unarchiver = _unarchiver;

- (void)setUnarchiver:(SUUnarchiver *)unarchiver
{
	if (_unarchiver != unarchiver) {
		if (_unarchiver.delegate == self) _unarchiver.delegate = nil;

		[_unarchiver release];
		_unarchiver = [unarchiver retain];

		_unarchiver.delegate = self;
	}
}

- (void)dealloc
{
	self.appcast = nil;
	self.unarchiver = nil;

	[updateItem release];
	[nonDeltaUpdateItem release];
	[download release];
	[downloadPath release];
	[tempDir release];
	[relaunchPath release];
	[super dealloc];
}

@end
