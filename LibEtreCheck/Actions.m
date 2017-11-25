/***********************************************************************
 ** Etresoft, Inc.
 ** Copyright (c) 2017. All rights reserved.
 **********************************************************************/

#import "Actions.h"
#import "Launchd.h"
#import "SubProcess.h"
#import "OSVersion.h"
#import "Utilities.h"
#import "EtreCheckConstants.h"
#import "NumberFormatter.h"
#import <Carbon/Carbon.h>
#import "LaunchdFile.h"
#import "LaunchdTask.h"
#import "LaunchdLoadedTask.h"
#import <sqlite3.h>
#import "UserNotification.h"

@implementation Actions

// Turn on Gatekeeper.
+ (void) enableGatekeeper
  {
  NSMutableString * command =
    [NSMutableString stringWithString: @"/usr/sbin/spctl --master-enable"];

  NSArray * statements =
    [NSArray arrayWithObject:
      [NSString
        stringWithFormat:
          @"do shell script(\"%@\") with administrator privileges",
          command]];
    
  // Execute the statements.
  [self executeAppleScriptStatements: statements];
  }

// Restart the machine.
+ (BOOL) restart
  {
  AEAddressDesc targetDesc;
  
  static const ProcessSerialNumber kPSNOfSystemProcess =
    { 0, kSystemProcess };
    
  AppleEvent eventReply = {typeNull, NULL};
  AppleEvent appleEventToSend = {typeNull, NULL};

  OSStatus error =
    AECreateDesc(
      typeProcessSerialNumber,
      & kPSNOfSystemProcess,
      sizeof(kPSNOfSystemProcess),
      & targetDesc);

  if(error != noErr)
    return NO;

  error =
    AECreateAppleEvent(
      kCoreEventClass,
      kAERestart,
      & targetDesc,
      kAutoGenerateReturnID,
      kAnyTransactionID,
      & appleEventToSend);

  AEDisposeDesc(& targetDesc);
  
  if(error != noErr)
    return NO;

  error =
    AESend(
      & appleEventToSend,
      & eventReply,
      kAENoReply,
      kAENormalPriority,
      kAEDefaultTimeout,
      NULL,
      NULL);

  AEDisposeDesc(& appleEventToSend);
  
  if(error != noErr)
    return NO;

  AEDisposeDesc(& eventReply);

  return YES;
  }

// Reveal a file in the Finder.
+ (void) revealFile: (NSString *) file
  {
  NSString * path = [file stringByExpandingTildeInPath];
  
  if([[NSFileManager defaultManager] fileExistsAtPath: path])
    {
    NSURL * url = [[NSURL alloc] initFileURLWithPath: path];
    
    NSArray * urls = [[NSArray alloc] initWithObjects: url, nil];
    
    [url release];
    
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs: urls];
    
    [urls release];
    }
  }
  
// Open a file in the default app.
+ (void) openFile: (NSString *) file
  {
  NSString * path = [file stringByExpandingTildeInPath];

  [[NSWorkspace sharedWorkspace] openFile: path];
  }
  
// Open a URL in the default web browser.
+ (void) openURL: (NSURL *) url
  {
  [[NSWorkspace sharedWorkspace] openURL: url];
  }
  
// Uninstall launchd files.
+ (nullable NSArray *) uninstall: (nonnull NSArray *) files
  {
  if(files.count > 0)
    {
    NSMutableSet * filesToUninstall = 
      [[NSMutableSet alloc] initWithArray: files];
  
    NSArray * uninstalledUserFiles = 
      [self uninstallUserFiles: filesToUninstall];
      
    for(LaunchdFile * file in uninstalledUserFiles)
      [filesToUninstall removeObject: file];
      
    NSArray * filesUninstalled =
      [self uninstallSystemFiles: filesToUninstall];
      
    [filesToUninstall release];
    
    return filesUninstalled;
    }
    
  return nil;
  }

// Load a launchd file.
+ (void) load: (nonnull LaunchdFile *) file
  completion: (nonnull LaunchdCompletion) completion
  {
  dispatch_async(
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), 
    ^{  
      NSSet * files = [[NSSet alloc] initWithObjects: file, nil];
      
      if([file.path hasPrefix: @"/System/Library/"])
        [self loadSystemFiles: files];
      
      else if([file.path hasPrefix: @"/Library/"])
        [self loadSystemFiles: files];
      
      else if([file.path hasPrefix: @"/Library/"])
        [self loadUserFiles: files];
      
      [files release];
      
      if(completion != nil)
        completion(file);
    });
  }

// Unload a launchd file.
+ (void) unload: (nonnull LaunchdFile *) file
  completion: (nonnull LaunchdCompletion) completion
  {
  dispatch_async(
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), 
    ^{  
      NSSet * files = [[NSSet alloc] initWithObjects: file, nil];
      
      if([file.path hasPrefix: @"/System/Library/"])
        [self unloadSystemFiles: files];
      
      else if([file.path hasPrefix: @"/Library/"])
        [self unloadSystemFiles: files];
      
      else if([file.path hasPrefix: @"/Library/"])
        [self unloadUserFiles: files];
      
      [files release];
      
      if(completion != nil)
        completion(file);
    });
  }

// Purge user notifications.
+ (void) purgeUserNotifications: (NSArray *) notifications
  {
  if(notifications.count == 0)
    return;
    
  char user_dir[1024];
  
  size_t size = confstr(_CS_DARWIN_USER_DIR, user_dir, 1024);
  
  if(size >= 1023)
    return;
  
  NSString * path =
    [[NSString stringWithUTF8String: user_dir]
      stringByAppendingPathComponent:
        @"com.apple.notificationcenter/db/db"];
  
  sqlite3 * handle = NULL;
  
  int result = sqlite3_open(path.fileSystemRepresentation, & handle);
  
  NSMutableArray * note_ids = [NSMutableArray new];
  
  for(UserNotification * notification in notifications)
    [note_ids addObject: notification.noteID];
    
  if(result == SQLITE_OK)
    {
    NSString * arguments = [note_ids componentsJoinedByString: @","];
    
    NSString * SQL =
      [NSString
        stringWithFormat:
          @"delete from notifications where note_id in (%@);", arguments];
    
    result = sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);
    
    SQL =
      [NSString
        stringWithFormat:
          @"delete from scheduled_notifications where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);

    SQL =
      [NSString
        stringWithFormat:
          @"delete from presented_notifications where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);

    SQL =
      [NSString
        stringWithFormat:
          @"delete from presented_alerts where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);

    SQL =
      [NSString
        stringWithFormat:
          @"delete from today_summary_notifications where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);

    SQL =
      [NSString
        stringWithFormat:
          @"delete from tomorrow_summary_notifications where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);

    SQL =
      [NSString
        stringWithFormat:
          @"delete from notification_source where note_id in (%@);",
          arguments];
    
    sqlite3_exec(handle, SQL.UTF8String, NULL, NULL, NULL);
    }
    
  [note_ids release];
  
  sqlite3_close(handle);
  }

// Trash files.
// There is no difference between privileged and unprivileged modes. The
// Finder handles that.
+ (void) trashFiles: (nonnull NSArray *) files
  completion: (nonnull TrashCompletion) completion
  {
  dispatch_async(
    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), 
    ^{  
      NSMutableArray * appleScriptStatements = [NSMutableArray new];
      
      // Build the statements I will need.
      [appleScriptStatements
        addObjectsFromArray: [self buildTrashStatements: files]];
      
      // Execute the statements. 
      [self executeAppleScriptStatements: appleScriptStatements];
      
      [appleScriptStatements release];
      
      NSMutableArray * trashedFiles = [NSMutableArray array];
      
      if(trashedFiles.count > 0)
        {
        for(NSString * path in files)
          if(![[NSFileManager defaultManager] fileExistsAtPath: path])
            [trashedFiles addObject: path];
            
        [self recordTrashedFiles: trashedFiles];
        }
        
      if(completion != nil)
        completion(trashedFiles);
      });
  }

#pragma mark - Private methods

// Execute a list of AppleScript statements.
+ (void) executeAppleScriptStatements: (NSArray *) statements
  {
  if([statements count] == 0)
    return;
    
  NSMutableArray * arguments = [NSMutableArray new];
  
  for(NSString * statement in statements)
    if([statement length])
      {
      [arguments addObject: @"-e"];
      [arguments addObject: statement];
      }
    
  if([arguments count] > 0)
    {
    NSLog(@"Executing AppleScript: %@", arguments);
    
    SubProcess * subProcess = [[SubProcess alloc] init];

    [subProcess execute: @"/usr/bin/osascript" arguments: arguments];

    [subProcess release];
    }
    
  [arguments release];
  }

// Uninstall user files.
// Returns files that were successfully uninstalled.
+ (NSArray *) uninstallUserFiles: (NSMutableSet *) filesToUninstall
  {
  NSSet * userFiles = [self findUserFiles: filesToUninstall];
  
  if(userFiles.count > 0)
    {
    NSSet * unloadedUserFiles = [self unloadUserFiles: userFiles];
  
    if(unloadedUserFiles.count > 0)
      return [self trashFiles: [unloadedUserFiles allObjects]];
    }
    
  return nil;
  }
  
// Uninstall system files.
// Returns files that were successfully uninstalled.
+ (NSArray *) uninstallSystemFiles: (NSMutableSet *) filesToUninstall
  {
  if(filesToUninstall.count > 0)
    {
    NSSet * unloadedSystemFiles = 
      [self unloadSystemFiles: filesToUninstall];
  
    if(unloadedSystemFiles.count > 0)
      return [self trashFiles: [unloadedSystemFiles allObjects]];
    }
    
  return nil;
  }

// Find all files that appear to be in the user context and will not need
// administrator privileges.
+ (NSSet *) findUserFiles: (NSSet *) files
  {
  NSMutableSet * userFiles = [NSMutableSet set];
  
  for(LaunchdFile * file in files)
    if([file.context isEqualToString: kLaunchdUserContext])
      [userFiles addObject: files];
      
  return userFiles;
  }
  
// Load user files.
// Returns all files successfully loaded.
+ (NSSet *) loadUserFiles: (NSSet *) files
  {
  NSMutableSet * unloadedFiles = [NSMutableSet new];
  
  for(LaunchdFile * file in files)
    if(!file.loaded)
      [unloadedFiles addObject: file];
      
  [self loadLaunchdFilesInUserSpace: [unloadedFiles allObjects]];
  
  NSMutableSet * loadedFiles = [NSMutableSet set];
  
  for(LaunchdFile * file in unloadedFiles)
    {
    if(!file.loaded)
      [file requery];
    
    if(file.loaded)
      [loadedFiles addObject: file];
    }
        
  [unloadedFiles release];

  return loadedFiles;
  }

// Unload user files.
// Returns all files successfully unloaded.
+ (NSSet *) unloadUserFiles: (NSSet *) files
  {
  NSMutableSet * loadedFiles = [NSMutableSet new];
  
  for(LaunchdFile * file in files)
    if(file.loaded)
      [loadedFiles addObject: file];
      
  [self unloadLaunchdFilesInUserSpace: [loadedFiles allObjects]];
  [self killLaunchdFilesInUserSpace: [loadedFiles allObjects]];
  
  NSMutableSet * unloadedFiles = [NSMutableSet set];
  
  for(LaunchdFile * file in loadedFiles)
    {
    if(file.loaded)
      [file requery];
    
    if(!file.loaded)
      [unloadedFiles addObject: file];
    }
        
  [loadedFiles release];

  return unloadedFiles;
  }
  
// Load launchd files in userspace.
+ (void) loadLaunchdFilesInUserSpace: (NSArray *) files
  {
  NSArray * args = [self buildLoadArguments: files];
  
  if([args count] > 2)
    {
    SubProcess * load = [[SubProcess alloc] init];

    [load execute: @"/bin/launchctl" arguments: args];

    [load release];
    }
  }

// Unload launchd files in userspace.
+ (void) unloadLaunchdFilesInUserSpace: (NSArray *) files
  {
  NSArray * args = [self buildUnloadArguments: files];
  
  if([args count] > 2)
    {
    SubProcess * unload = [[SubProcess alloc] init];

    [unload execute: @"/bin/launchctl" arguments: args];

    [unload release];
    }
  }

// Build an argument list for a load command for a list of launchd files.
+ (NSArray *) buildLoadArguments: (NSArray *) files
  {
  NSMutableArray * arguments = [NSMutableArray array];
  
  [arguments addObject: @"load"];
  [arguments addObject: @"-wF"];
  
  for(LaunchdFile * file in files)
    {
    // If it is already loaded, don't try to load.
    if(file.loaded)
      continue;
      
    if(file.path.length > 0)
      [arguments addObject: file.path];
    }
    
  return arguments;
  }

// Build an argument list for an unload command for a list of launchd files.
+ (NSArray *) buildUnloadArguments: (NSArray *) files
  {
  NSMutableArray * arguments = [NSMutableArray array];
  
  [arguments addObject: @"unload"];
  [arguments addObject: @"-wF"];
  
  for(LaunchdFile * file in files)
    {
    // If it isn't already loaded, don't try to unload.
    if(!file.loaded)
      continue;
      
    if(file.path.length > 0)
      [arguments addObject: file.path];
    }
    
  return arguments;
  }

// Kill launchd tasks in userspace.
+ (void) killLaunchdFilesInUserSpace: (NSArray *) files
  {
  NSArray * args = [self buildKillArguments: files];
  
  if([args count] > 1)
    {
    SubProcess * kill = [[SubProcess alloc] init];

    [kill execute: @"/bin/kill" arguments: args];

    [kill release];
    }
  }

// Build an argument list for a kill command for a list of launchd files.
+ (NSArray *) buildKillArguments: (NSArray *) files
  {
  NSMutableArray * arguments = [NSMutableArray array];
  
  [arguments addObject: @"-9"];

  NumberFormatter * formatter = [NumberFormatter sharedNumberFormatter];
  
  for(LaunchdFile * file in files)
    for(LaunchdLoadedTask * task in file.loadedTasks)
      {
      NSNumber * PID = [formatter convertFromString: task.PID];
      
      if(PID.intValue > 0)
        [arguments addObject: task.PID];
      }
    
  return arguments;
  }

// Query the status of a process.
+ (NSString *) ps: (NSNumber *) pid
  {
  NSString * line = nil;
  
  SubProcess * ps = [[SubProcess alloc] init];
  
  if([ps execute: @"/bin/ps" arguments: @[ [pid stringValue] ]])
    {
    NSArray * lines = [Utilities formatLines: ps.standardOutput];
    
    if([lines count] > 1)
      line = [lines objectAtIndex: 1];
    }
    
  [ps release];
  
  return line;
  }

// Load system files.
// Returns all files successfully loaded.
+ (NSSet *) loadSystemFiles: (NSSet *) files
  {
  NSMutableSet * unloadedFiles = [NSMutableSet new];
  
  for(LaunchdFile * file in files)
    if(!file.loaded)
      [unloadedFiles addObject: file];
      
  [self loadLaunchdFilesInSystemSpace: [unloadedFiles allObjects]];
  
  NSMutableSet * loadedFiles = [NSMutableSet set];
  
  for(LaunchdFile * file in unloadedFiles)
    {
    if(!file.loaded)
      [file requery];
    
    if(file.loaded)
      [loadedFiles addObject: file];
    }
        
  [unloadedFiles release];

  return loadedFiles;
  }

// Unload system files.
// Returns all files successfully unloaded.
+ (NSSet *) unloadSystemFiles: (NSSet *) files
  {
  NSMutableSet * loadedFiles = [NSMutableSet new];
  
  for(LaunchdFile * file in files)
    if(file.loaded)
      [loadedFiles addObject: file];
      
  [self unloadLaunchdFilesInSystemSpace: [loadedFiles allObjects]];
  
  NSMutableSet * unloadedFiles = [NSMutableSet set];
  
  for(LaunchdFile * file in loadedFiles)
    {
    if(file.loaded)
      [file requery];
    
    if(!file.loaded)
      [unloadedFiles addObject: file];
    }
        
  [loadedFiles release];

  return unloadedFiles;
  }

// Load launchd files in system space.
+ (void) loadLaunchdFilesInSystemSpace: (NSArray *) files
  {
  NSMutableArray * appleScriptStatements = [NSMutableArray new];
  
  // Build the statements I will need.
  [appleScriptStatements
    addObjectsFromArray: [self buildLoadStatements: files]];
  
  // Execute the statements.
  [self executeAppleScriptStatements: appleScriptStatements];
  
  [appleScriptStatements release];
  }

// Unload launchd files in system space.
+ (void) unloadLaunchdFilesInSystemSpace: (NSArray *) files
  {
  NSMutableArray * appleScriptStatements = [NSMutableArray new];
  
  // Build the statements I will need.
  [appleScriptStatements
    addObjectsFromArray: [self buildUnloadStatements: files]];
  [appleScriptStatements
    addObjectsFromArray: [self buildKillStatement: files]];
  
  // Execute the statements.
  [self executeAppleScriptStatements: appleScriptStatements];
  
  [appleScriptStatements release];
  }

// Build one or more AppleScript statements to load a list of
// launchd files.
+ (NSArray *) buildLoadStatements: (NSArray *) files
  {
  NSMutableArray * statements = [NSMutableArray array];
  
  NSMutableString * command = [NSMutableString new];

  NSArray * arguments = [self buildLoadArguments: files];
  
  if(arguments.count > 2)
    {
    [command appendString: @"/bin/launchctl"];
    
    for(NSString * argument in arguments)
      [command appendFormat: @" %@", argument];
      
    [statements addObject:
      [NSString
        stringWithFormat:
          @"do shell script(\"%@\") with administrator privileges",
          command]];
          
    [command release];
    }
    
  return statements;
  }

// Build one or more AppleScript statements to unload a list of
// launchd files.
+ (NSArray *) buildUnloadStatements: (NSArray *) files
  {
  NSMutableArray * statements = [NSMutableArray array];
  
  NSMutableString * command = [NSMutableString new];

  NSArray * arguments = [self buildUnloadArguments: files];
  
  if(arguments.count > 2)
    {
    [command appendString: @"/bin/launchctl"];
    
    for(NSString * argument in arguments)
      [command appendFormat: @" %@", argument];
      
    [statements addObject:
      [NSString
        stringWithFormat:
          @"do shell script(\"%@\") with administrator privileges",
          command]];
          
    [command release];
    }
    
  return statements;
  }

// Build an AppleScript statement to kill a list of launchd files.
+ (NSArray *) buildKillStatement: (NSArray *) files
  {
  NSMutableArray * statements = [NSMutableArray array];
  
  NSMutableString * command = [NSMutableString new];

  NSArray * arguments = [self buildKillArguments: files];
  
  if(arguments.count > 1)
    {
    [command appendString: @"/bin/kill"];
    
    for(NSString * argument in arguments)
      [command appendFormat: @" %@", argument];
      
    [statements addObject:
      [NSString
        stringWithFormat:
          @"do shell script(\"%@\") with administrator privileges",
          command]];
    
    [command release];
    }
    
  return statements;
  }

// Build an AppleScript statement to trash a list of files.
+ (NSArray *) buildTrashStatements: (NSArray *) paths
  {
  NSMutableArray * statements = [NSMutableArray array];
  
  NSMutableString * source = [NSMutableString string];
  
  [source appendString: @"set posixFiles to {"];
  
  int i = 0;
  
  for(NSString * path in paths)
    {
    if(i)
      [source appendString: @","];
      
    [source appendFormat: @"POSIX file \"%@\"", path];
    
    ++i;
    }

  [source appendString: @"}"];

  // Return an empty string that won't crash but can be ignored later.
  if(i > 0)
    {
    [statements addObject: source];
    
    [statements addObject: @"tell application \"Finder\""];
    [statements addObject: @"activate"];
    [statements addObject: @"repeat with posixFile in posixFiles"];
    [statements addObject: @"set f to posixFile as alias"];
    [statements addObject: @"set locked of f to false"];
    [statements addObject: @"end repeat"];
    [statements addObject: @"move posixFiles to the trash"];
    [statements addObject: @"end tell"];
    }
    
  return statements;
  }

// Record trashed files in preferences.
+ (void) recordTrashedFiles: (NSArray *) files
  {
  // Save deleted files.
  NSArray * currentDeletedFiles =
    [[NSUserDefaults standardUserDefaults]
      objectForKey: @"deletedfiles"];
    
  NSMutableArray * deletedFiles = [NSMutableArray array];
  
  if([currentDeletedFiles count])
    {
    // Remove any old files.
    NSDate * then =
      [[NSDate date] dateByAddingTimeInterval: -60 * 60 * 24 * 7];
    
    for(NSDictionary * entry in currentDeletedFiles)
      {
      NSDate * date = [entry objectForKey: @"date"];
      
      if([then compare: date] == NSOrderedAscending)
        [deletedFiles addObject: entry];
      }
    }
    
  NSDate * now = [NSDate date];
  
  // Add newly deleted files.
  for(NSString * path in files)
    {
    NSDictionary * entry =
      [NSDictionary
        dictionaryWithObjectsAndKeys:
          now, @"date",
          path, @"file",
          nil];
      
    [deletedFiles addObject: entry];
    }

  [[NSUserDefaults standardUserDefaults]
    setObject: deletedFiles forKey: @"deletedfiles"];
  }

@end
