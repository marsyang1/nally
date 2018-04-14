//
//  YLSSH.m
//  Nally
//
//  Created by Lan Yung-Luen on 12/7/07.
//  Copyright 2007 yllan.org. All rights reserved.
//

/* Code from iTerm : PTYTask.m */

#import "YLSSH.h"
#import "YLLGlobalConfig.h"
#include <util.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <termios.h>
#include <stdarg.h>

#define CTRLKEY(c)   ((c)-'A'+1)

@implementation YLSSH

- (YLSSH *) init
{
    self = [super init];
    if (self) {
        _pid = 0;
        _fileDescriptor = -1;
        _loginAsBBS = NO;
    }
    return self;
}

- (void) dealloc
{
    NSLog(@"dealloc");
    if (_pid > 0)
        kill(_pid, SIGKILL);
    
    if (_fileDescriptor >= 0)
        close(_fileDescriptor);
    
    [super dealloc];
}

- (void) close
{
    if (_pid > 0)
        kill(_pid, SIGKILL);
    if (_fileDescriptor >= 0)
        close(_fileDescriptor);
    _fileDescriptor = -1;
    _pid = 0;
    [self setConnected: NO];
}

- (void) reconnect
{
    [self close];
    [self performSelector: @selector(connectToAddress:) withObject: [self connectionAddress] afterDelay: 0.01];
}

- (BOOL) connectToAddress: (NSString *)addr
{
    if (NO) {
    } else if ([addr hasPrefix: @"ssh://bbs"]) {
        addr = [addr substringFromIndex: 6];
        _loginAsBBS = YES;
    } else if ([addr hasPrefix: @"ssh://"]) {
        addr = [addr substringFromIndex: 6];
		_loginAsBBS = NO;
    }
    NSArray *a = [addr componentsSeparatedByString: @":"];
    if ([a count] == 2) {
        int p = [[a objectAtIndex: 1] intValue];
        if (p > 0) {
            return [self connectToAddress: [a objectAtIndex: 0] port: p];            
        } else {
            return [self connectToAddress: [a objectAtIndex: 0] port: 22];
        }
    } else if ([a count] == 1) {
        return [self connectToAddress: addr port: 22];
    }
    return NO;
}

- (BOOL) connectToAddress: (NSString *)addr port: (unsigned int)port
{
    [_terminal clearAll];
    
    char slaveName[PATH_MAX];
    struct termios term;
    struct winsize size;
    
    term.c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
    term.c_oflag = OPOST | ONLCR;
    term.c_cflag = CREAD | CS8 | HUPCL;
    term.c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;
	
    term.c_cc[VEOF]      = CTRLKEY('D');
    term.c_cc[VEOL]      = -1;
    term.c_cc[VEOL2]     = -1;
    term.c_cc[VERASE]    = 0x7f;	// DEL
    term.c_cc[VWERASE]   = CTRLKEY('W');
    term.c_cc[VKILL]     = CTRLKEY('U');
    term.c_cc[VREPRINT]  = CTRLKEY('R');
    term.c_cc[VINTR]     = CTRLKEY('C');
    term.c_cc[VQUIT]     = 0x1c;	// Control+backslash
    term.c_cc[VSUSP]     = CTRLKEY('Z');
    term.c_cc[VDSUSP]    = CTRLKEY('Y');
    term.c_cc[VSTART]    = CTRLKEY('Q');
    term.c_cc[VSTOP]     = CTRLKEY('S');
    term.c_cc[VLNEXT]    = -1;
    term.c_cc[VDISCARD]  = -1;
    term.c_cc[VMIN]      = 1;
    term.c_cc[VTIME]     = 0;
    term.c_cc[VSTATUS]   = -1;
	
    term.c_ispeed = B38400;
    term.c_ospeed = B38400;
    size.ws_col = [[YLLGlobalConfig sharedInstance] column];
    size.ws_row = [[YLLGlobalConfig sharedInstance] row];
    size.ws_xpixel = 0;
    size.ws_ypixel = 0;
    
    _pid = forkpty(&_fileDescriptor, slaveName, &term, &size);
    if (_pid == 0) { /* child */
        if (_loginAsBBS) {
            execlp("/usr/bin/ssh", "ssh", "-e",
                   "none", // do not use EscapeChar
                   "-x", "-p",
                   [[NSString stringWithFormat: @"%d", port] UTF8String],
                   [addr UTF8String], NULL);
            fprintf(stderr, "fork error");
        } else {
            // should be customizable in the future
            const char *envp[] = { "TERM=vt102", NULL };
            execle("/usr/bin/ssh", "ssh",
                   "-e", "none", // do not use EscapeChar
                   "-p", [[NSString stringWithFormat: @"%d", port] UTF8String],
                   [addr UTF8String], NULL, envp);
            fprintf(stderr, "fork error");
        }
    } else { /* parent */
        int one = 1;
        ioctl(_fileDescriptor, TIOCPKT, &one);
        [NSThread detachNewThreadSelector: @selector(readLoop:) toTarget:[self class] withObject: self];
    }
    
    [self setConnected: YES];
    return YES;
}

- (void) receiveData: (NSData *)data
{
    [self receiveBytes: (unsigned char *)[data bytes] length: [data length]];
}

- (void) receiveBytes: (unsigned char *)bytes length: (NSUInteger)length
{
    [_terminal feedBytes: bytes length: length connection: self];
}

- (void) sendBytes: (unsigned char *)bytes length: (NSInteger)length
{
    fd_set writeFileDescriptorSet, errorFileDescriptorSet;
    struct timeval timeout;
    int chunkSize;
    
    if (_fileDescriptor < 0) return;
    
    [_lastTouchDate release];
    _lastTouchDate = [[NSDate date] retain];

    while (length > 0) {
        FD_ZERO(&writeFileDescriptorSet);
        FD_ZERO(&errorFileDescriptorSet);
        FD_SET(_fileDescriptor, &writeFileDescriptorSet);
        FD_SET(_fileDescriptor, &errorFileDescriptorSet);
        
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;
        
        int result = select(_fileDescriptor + 1, NULL, &writeFileDescriptorSet, &errorFileDescriptorSet, &timeout);
        
        if (result == 0) {
            NSLog(@"timeout!");
            break;
        } else if (result < 0) { /* error */
            [self close];    
            break;
        }
        
        if (length > 4096) chunkSize = 4096;
        else chunkSize = length;
        
        int size = write(_fileDescriptor, bytes, chunkSize);
        
        bytes += size;
        length -= size;
    }
}

- (void) sendData: (NSData *)data
{
    [self sendBytes: (unsigned char *)[data bytes] length: [data length]];
}

#pragma mark -
#pragma mark 

+ (void) readLoop: (YLSSH *)boss
{
    fd_set readFileDescriptorSet, errorFileDescriptorSet;
    BOOL exit = NO;
    unsigned char buf[4096];
    int iterationCount = 0;
    int result;
    
    while (!exit) {
        iterationCount++;

//        if (_fileDescriptor < 0) {
//            [self performSelectorOnMainThread: @selector(close) withObject:nil waitUntilDone: YES];
//            break;
//        }

        FD_ZERO(&readFileDescriptorSet);
        FD_ZERO(&errorFileDescriptorSet);
        
        FD_SET(boss->_fileDescriptor, &readFileDescriptorSet);
        FD_SET(boss->_fileDescriptor, &errorFileDescriptorSet);

        result = select(boss->_fileDescriptor + 1, &readFileDescriptorSet, NULL, &errorFileDescriptorSet, NULL);

        if (result < 0) { /* error */
            break;
        } else if (FD_ISSET(boss->_fileDescriptor, &errorFileDescriptorSet)) {
            result = read(boss->_fileDescriptor, buf, 1);
            if (result == 0) { // session close
                exit = YES;
            }
        } else if (FD_ISSET(boss->_fileDescriptor, &readFileDescriptorSet)) {
            result = read(boss->_fileDescriptor, buf, sizeof(buf));
            if (result > 1) {
                [boss performSelectorOnMainThread: @selector(receiveData:) 
                                       withObject: [NSData dataWithBytes: buf + 1 length: result - 1]
                                    waitUntilDone: NO];
            }
            if (result == 0) {
                exit = YES;
            }
        }
        
        if (iterationCount % 5000 == 0) {
            iterationCount = 1;
        }
    }
    
    if (result >= 0) {
        [boss performSelectorOnMainThread: @selector(close) withObject:nil waitUntilDone:NO];
    }
    
    [NSThread exit];
}
@end
