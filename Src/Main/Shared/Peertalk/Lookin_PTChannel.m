#ifdef SHOULD_COMPILE_LOOKIN_SERVER 

#import "Lookin_PTChannel.h"
#import "Lookin_PTPrivate.h"
#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>
#include <fcntl.h>
#include <arpa/inet.h>
#import <objc/runtime.h>

// Read member of sockaddr_in without knowing the family
#define PT_SOCKADDR_ACCESS(ss, member4, member6) \
  (((ss)->ss_family == AF_INET) ? ( \
    ((const struct sockaddr_in *)(ss))->member4 \
  ) : ( \
    ((const struct sockaddr_in6 *)(ss))->member6 \
  ))

// Connection state (storage: uint8_t)
#define kConnStateNone 0
#define kConnStateConnecting 1
#define kConnStateConnected 2
#define kConnStateListening 3

// Delegate support optimization (storage: uint8_t)
#define kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize 1
#define kDelegateFlagImplements_ioFrameChannel_didEndWithError 2
#define kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress 4


static int ChannelInstanceCount = 0;
static int ChannelUniqueID = 0;

#pragma mark -
// Note: We are careful about the size of this struct as each connected peer
// implies one allocation of this struct.
@interface Lookin_PTChannel () {
  dispatch_io_t dispatchObj_channel_;
  dispatch_source_t dispatchObj_source_;
  NSError *endError_;              // 64 bit
@public  // here be hacks
  id<Lookin_PTChannelDelegate> delegate_; // 64 bit
  uint8_t delegateFlags_;             // 8 bit
@private
  uint8_t connState_;                 // 8 bit
  //char padding_[6];              // 48 bit -- only if allocation speed is important
}
- (id)initWithProtocol:(Lookin_PTProtocol*)protocol delegate:(id<Lookin_PTChannelDelegate>)delegate;
- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD;
@end
static const uint8_t kUserInfoKey;

#pragma mark -
@interface Lookin_PTData ()
- (id)initWithMappedDispatchData:(dispatch_data_t)mappedContiguousData data:(void*)data length:(size_t)length;
@end

#pragma mark -
@interface Lookin_PTAddress () {
  struct sockaddr_storage sockaddr_;
}
- (id)initWithSockaddr:(const struct sockaddr_storage*)addr;
@end

#pragma mark -
@implementation Lookin_PTChannel

@synthesize protocol = protocol_;


+ (Lookin_PTChannel*)channelWithDelegate:(id<Lookin_PTChannelDelegate>)delegate {
  return [[Lookin_PTChannel alloc] initWithProtocol:[Lookin_PTProtocol sharedProtocolForQueue:dispatch_get_main_queue()] delegate:delegate];
}


- (id)initWithProtocol:(Lookin_PTProtocol*)protocol delegate:(id<Lookin_PTChannelDelegate>)delegate {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
  self.delegate = delegate;
    
    [self didInit];
    
  return self;
}


- (id)initWithProtocol:(Lookin_PTProtocol*)protocol {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
    
    [self didInit];
    
  return self;
}


- (id)init {
    [self didInit];
    
  return [self initWithProtocol:[Lookin_PTProtocol sharedProtocolForQueue:dispatch_get_main_queue()]];
}

- (void)didInit {
    ChannelUniqueID++;
    ChannelInstanceCount++;
    self.uniqueID = ChannelUniqueID;
    NSLog(@"LookinServer - Init channel(ID: %@). Total count: %@", @(self.uniqueID), @(ChannelInstanceCount));
}

- (void)dealloc {
    ChannelInstanceCount--;
    NSLog(@"LookinServer - Dealloc channel%@. Still lives count: %@", self.debugTag, @(ChannelInstanceCount));
#if PT_DISPATCH_RETAIN_RELEASE
  if (dispatchObj_channel_) dispatch_release(dispatchObj_channel_);
  else if (dispatchObj_source_) dispatch_release(dispatchObj_source_);
#endif
}


- (BOOL)isConnected {
  return connState_ == kConnStateConnecting || connState_ == kConnStateConnected;
}


- (BOOL)isListening {
  return connState_ == kConnStateListening;
}


- (id)userInfo {
  return objc_getAssociatedObject(self, (void*)&kUserInfoKey);
}

- (void)setUserInfo:(id)userInfo {
  objc_setAssociatedObject(self, (const void*)&kUserInfoKey, userInfo, OBJC_ASSOCIATION_RETAIN);
}


- (void)setConnState:(char)connState {
  connState_ = connState;
}


- (void)setDispatchChannel:(dispatch_io_t)channel {
  assert(connState_ == kConnStateConnecting || connState_ == kConnStateConnected || connState_ == kConnStateNone);
  dispatch_io_t prevChannel = dispatchObj_channel_;
  if (prevChannel != channel) {
    dispatchObj_channel_ = channel;
#if PT_DISPATCH_RETAIN_RELEASE
    if (dispatchObj_channel_) dispatch_retain(dispatchObj_channel_);
    if (prevChannel) dispatch_release(prevChannel);
#endif
    if (!dispatchObj_channel_ && !dispatchObj_source_) {
      connState_ = kConnStateNone;
    }
  }
}


- (void)setDispatchSource:(dispatch_source_t)source {
  assert(connState_ == kConnStateListening || connState_ == kConnStateNone);
  dispatch_source_t prevSource = dispatchObj_source_;
  if (prevSource != source) {
    dispatchObj_source_ = source;
#if PT_DISPATCH_RETAIN_RELEASE
    if (dispatchObj_source_) dispatch_retain(dispatchObj_source_);
    if (prevSource) dispatch_release(prevSource);
#endif
    if (!dispatchObj_channel_ && !dispatchObj_source_) {
      connState_ = kConnStateNone;
    }
  }
}


- (id<Lookin_PTChannelDelegate>)delegate {
  return delegate_;
}


- (void)setDelegate:(id<Lookin_PTChannelDelegate>)delegate {
  delegate_ = delegate;
  delegateFlags_ = 0;
  if (!delegate_) {
    return;
  }
  
  if ([delegate respondsToSelector:@selector(ioFrameChannel:shouldAcceptFrameOfType:tag:payloadSize:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:didEndWithError:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_didEndWithError;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:didAcceptConnection:fromAddress:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress;
  }
}

- (NSString *)debugTag {
    NSString *state = @"";
    if (connState_ == kConnStateNone) {
        state = @"None";
    } else if (connState_ == kConnStateConnecting) {
        state = @"Connecting";
    } else if (connState_ == kConnStateConnected) {
        state = @"Connected";
    } else if (connState_ == kConnStateListening) {
        state = @"Listening";
    } else {
        state = @"Undefined";
    }
    return [NSString stringWithFormat:@"[%@-%@,%@]", @(self.uniqueID), @(self.targetPort), state];
}


//- (void)setFileDescriptor:(dispatch_fd_t)fd {
//  [self setDispatchChannel:dispatch_io_create(DISPATCH_IO_STREAM, fd, protocol_.queue, ^(int error) {
//    close(fd);
//  })];
//}


#pragma mark - Connecting


- (void)connectToPort:(int)port overUSBHub:(Lookin_PTUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback {
  assert(protocol_ != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  connState_ = kConnStateConnecting;
  [usbHub connectToDevice:deviceID port:port onStart:^(NSError *err, dispatch_io_t dispatchChannel) {
    NSError *error = err;
    if (!error) {
      [self startReadingFromConnectedChannel:dispatchChannel error:&error];
    } else {
        self->connState_ = kConnStateNone;
    }
    if (callback) callback(error);
  } onEnd:^(NSError *error) {
      if (self->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
          [self->delegate_ ioFrameChannel:self didEndWithError:error];
    }
      self->endError_ = nil;
  }];
}


- (void)connectToPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error, Lookin_PTAddress *address))callback {
  assert(protocol_ != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil], nil);
    return;
  }
  connState_ = kConnStateConnecting;
  
  int error = 0;
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    perror("socket(AF_INET, SOCK_STREAM, 0) failed");
    error = errno;
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil], nil);
    return;
  }
  
  // Connect socket
  struct sockaddr_in addr;
  bzero((char *)&addr, sizeof(addr));
  
  addr.sin_len = sizeof(addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = htonl(address);
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  // int socket, const struct sockaddr *address, socklen_t address_len
  if (connect(fd, (const struct sockaddr *)&addr, addr.sin_len) == -1) {
    //perror("connect");
    error = errno;
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil);
    return;
  }
  
  // get actual address
  //if (getsockname(fd, (struct sockaddr*)&addr, (socklen_t*)&addr.sin_len) == -1) {
  //  error = errno;
  //  close(fd);
  //  if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil);
  //  return;
  //}
  
  dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, fd, protocol_.queue, ^(int error) {
    close(fd);
      if (self->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
          NSError *err = error == 0 ? self->endError_ : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil];
          [self->delegate_ ioFrameChannel:self didEndWithError:err];
          self->endError_ = nil;
    }
  });
  
  if (!dispatchChannel) {
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:@"PTError" code:0 userInfo:nil], nil);
    return;
  }
  
  // Success
  NSError *err = nil;
  Lookin_PTAddress *ptAddr = [[Lookin_PTAddress alloc] initWithSockaddr:(struct sockaddr_storage*)&addr];
  [self startReadingFromConnectedChannel:dispatchChannel error:&err];
  if (callback) callback(err, ptAddr);
}


#pragma mark - Listening and serving


- (void)listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback {
  assert(dispatchObj_source_ == nil);
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  // Connect socket
  struct sockaddr_in addr;
  bzero((char *)&addr, sizeof(addr));
  
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = htonl(address);
  
  socklen_t socklen = sizeof(addr);
  
  int on = 1;
  
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (bind(fd, (struct sockaddr*)&addr, socklen) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (listen(fd, 512) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  [self setDispatchSource:dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, protocol_.queue)];
  
  dispatch_source_set_event_handler(dispatchObj_source_, ^{
      unsigned long nconns = dispatch_source_get_data(self->dispatchObj_source_);
    while ([self acceptIncomingConnection:fd] && --nconns);
  });
  
  dispatch_source_set_cancel_handler(dispatchObj_source_, ^{
    // Captures *self*, effectively holding a reference to *self* until cancelled.
      self->dispatchObj_source_ = nil;
    close(fd);
      if (self->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
          [self->delegate_ ioFrameChannel:self didEndWithError:self->endError_];
          self->endError_ = nil;
    }
  });
  
  dispatch_resume(dispatchObj_source_);
  //NSLog(@"%@ opened on fd #%d", self, fd);
  
  connState_ = kConnStateListening;
  if (callback) callback(nil);
}


- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD {
  struct sockaddr_in addr;
  socklen_t addrLen = sizeof(addr);
  dispatch_fd_t clientSocketFD = accept(serverSocketFD, (struct sockaddr*)&addr, &addrLen);
  
  if (clientSocketFD == -1) {
    perror("accept()");
    return NO;
  }
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(clientSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  if (fcntl(clientSocketFD, F_SETFL, O_NONBLOCK) == -1) {
    perror("fcntl(.. O_NONBLOCK)");
    close(clientSocketFD);
    return NO;
  }
  
  if (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress) {
    Lookin_PTChannel *peerChannel = [[Lookin_PTChannel alloc] initWithProtocol:protocol_ delegate:delegate_];
    __block Lookin_PTChannel *localChannelRef = self;
    dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocketFD, protocol_.queue, ^(int error) {
      // Important note: This block captures *self*, thus a reference is held to
      // *self* until the fd is truly closed.
      localChannelRef = nil;

      close(clientSocketFD);
      
      if (peerChannel->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
        NSError *err = error == 0 ? peerChannel->endError_ : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil];
        [peerChannel->delegate_ ioFrameChannel:peerChannel didEndWithError:err];
        peerChannel->endError_ = nil;
      }
    });
    
    [peerChannel setConnState:kConnStateConnected];
    [peerChannel setDispatchChannel:dispatchChannel];
    
    assert(((struct sockaddr_storage*)&addr)->ss_len == addrLen);
    Lookin_PTAddress *address = [[Lookin_PTAddress alloc] initWithSockaddr:(struct sockaddr_storage*)&addr];
    [delegate_ ioFrameChannel:self didAcceptConnection:peerChannel fromAddress:address];
    
    NSError *err = nil;
    if (![peerChannel startReadingFromConnectedChannel:dispatchChannel error:&err]) {
      NSLog(@"startReadingFromConnectedChannel failed in accept: %@", err);
    }
  } else {
    close(clientSocketFD);
  }
  return YES;
}


#pragma mark - Closing the channel


- (void)close {
    NSLog(@"LookinServer - Will close chanel: %@", self.debugTag);

  if ((connState_ == kConnStateConnecting || connState_ == kConnStateConnected) && dispatchObj_channel_) {
    dispatch_io_close(dispatchObj_channel_, DISPATCH_IO_STOP);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && dispatchObj_source_) {
    dispatch_source_cancel(dispatchObj_source_);
  }
}

/// 曾经连接上 Client，然后 Client 端关闭时，Peertalk 内部会对之前 connect 的 channel 调用该方法
- (void)cancel {
    NSLog(@"LookinServer - Will cancel chanel: %@", self.debugTag);
    
  if ((connState_ == kConnStateConnecting || connState_ == kConnStateConnected) && dispatchObj_channel_) {
    dispatch_io_close(dispatchObj_channel_, 0);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && dispatchObj_source_) {
    dispatch_source_cancel(dispatchObj_source_);
  }
}


#pragma mark - Reading


- (BOOL)startReadingFromConnectedChannel:(dispatch_io_t)channel error:(__autoreleasing NSError**)error {
  if (connState_ != kConnStateNone && connState_ != kConnStateConnecting && connState_ != kConnStateConnected) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil];
    return NO;
  }
  
  if (dispatchObj_channel_ != channel) {
    [self close];
    [self setDispatchChannel:channel];
  }
  
  connState_ = kConnStateConnected;
  
  // helper
  BOOL(^handleError)(NSError*,BOOL) = ^BOOL(NSError *error, BOOL isEOS) {
    if (error) {
      //NSLog(@"Error while communicating: %@", error);
        self->endError_ = error;
      [self close];
      return YES;
    } else if (isEOS) {
      [self cancel];
      return YES;
    }
    return NO;
  };
  
  [protocol_ readFramesOverChannel:channel onFrame:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize, dispatch_block_t resumeReadingFrames) {
    if (handleError(error, type == PTFrameTypeEndOfStream)) {
      return;
    }
    
      BOOL accepted = (channel == self->dispatchObj_channel_);
      if (accepted && (self->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize)) {
          accepted = [self->delegate_ ioFrameChannel:self shouldAcceptFrameOfType:type tag:tag payloadSize:payloadSize];
    }
    
    if (payloadSize == 0) {
        if (accepted && self->delegate_) {
            [self->delegate_ ioFrameChannel:self didReceiveFrameOfType:type tag:tag payload:nil];
      } else {
        // simply ignore the frame
      }
      resumeReadingFrames();
    } else {
      // has payload
      if (!accepted) {
        // Read and discard payload, ignoring frame
          [self->protocol_ readAndDiscardDataOfSize:payloadSize overChannel:channel callback:^(NSError *error, BOOL endOfStream) {
          if (!handleError(error, endOfStream)) {
            resumeReadingFrames();
          }
        }];
      } else {
          [self->protocol_ readPayloadOfSize:payloadSize overChannel:channel callback:^(NSError *error, dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
          if (handleError(error, bufferSize == 0)) {
            return;
          }
          
              if (self->delegate_) {
            Lookin_PTData *payload = [[Lookin_PTData alloc] initWithMappedDispatchData:contiguousData data:(void*)buffer length:bufferSize];
                  [self->delegate_ ioFrameChannel:self didReceiveFrameOfType:type tag:tag payload:payload];
          }
          
          resumeReadingFrames();
        }];
      }
    }
  }];
  
  return YES;
}


#pragma mark - Sending

- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback {
  if (connState_ == kConnStateConnecting || connState_ == kConnStateConnected) {
    [protocol_ sendFrameOfType:frameType tag:tag withPayload:payload overChannel:dispatchObj_channel_ callback:callback];
  } else if (callback) {
    callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
  }
}

#pragma mark - NSObject

- (NSString*)description {
  id userInfo = objc_getAssociatedObject(self, (void*)&kUserInfoKey);
  return [NSString stringWithFormat:@"<Lookin_PTChannel: %p (%@)%s%@>", self, (  connState_ == kConnStateConnecting ? @"connecting"
                                                                    : connState_ == kConnStateConnected  ? @"connected" 
                                                                    : connState_ == kConnStateListening  ? @"listening"
                                                                    :                                      @"closed"),
          userInfo ? " " : "", userInfo ? userInfo : @""];
}


@end


#pragma mark -
@implementation Lookin_PTAddress

- (id)initWithSockaddr:(const struct sockaddr_storage*)addr {
  if (!(self = [super init])) return nil;
  assert(addr);
  memcpy((void*)&sockaddr_, (const void*)addr, addr->ss_len);  
  return self;
}


- (NSString*)name {
  if (sockaddr_.ss_len) {
    const void *sin_addr = NULL;
    size_t bufsize = 0;
    if (sockaddr_.ss_family == AF_INET6) {
      bufsize = INET6_ADDRSTRLEN;
      sin_addr = (const void *)&((const struct sockaddr_in6*)&sockaddr_)->sin6_addr;
    } else {
      bufsize = INET_ADDRSTRLEN;
      sin_addr = (const void *)&((const struct sockaddr_in*)&sockaddr_)->sin_addr;
    }
    char *buf = CFAllocatorAllocate(kCFAllocatorDefault, bufsize+1, 0);
    if (inet_ntop(sockaddr_.ss_family, sin_addr, buf, (unsigned int)bufsize-1) == NULL) {
      CFAllocatorDeallocate(kCFAllocatorDefault, buf);
      return nil;
    }
    return [[NSString alloc] initWithBytesNoCopy:(void*)buf length:strlen(buf) encoding:NSUTF8StringEncoding freeWhenDone:YES];
  } else {
    return nil;
  }
}


- (NSInteger)port {
  if (sockaddr_.ss_len) {
    return ntohs(PT_SOCKADDR_ACCESS(&sockaddr_, sin_port, sin6_port));
  } else {
    return 0;
  }
}


- (NSString*)description {
  if (sockaddr_.ss_len) {
    return [NSString stringWithFormat:@"%@:%u", self.name, (unsigned)self.port];
  } else {
    return @"(?)";
  }
}

@end


#pragma mark -
@implementation Lookin_PTData

@synthesize dispatchData = dispatchData_;
@synthesize data = data_;
@synthesize length = length_;

- (id)initWithMappedDispatchData:(dispatch_data_t)mappedContiguousData data:(void*)data length:(size_t)length {
  if (!(self = [super init])) return nil;
  dispatchData_ = mappedContiguousData;
#if PT_DISPATCH_RETAIN_RELEASE
  if (dispatchData_) dispatch_retain(dispatchData_);
#endif
  data_ = data;
  length_ = length;
  return self;
}

- (void)dealloc {
#if PT_DISPATCH_RETAIN_RELEASE
  if (dispatchData_) dispatch_release(dispatchData_);
#endif
  data_ = NULL;
  length_ = 0;
}

#pragma mark - NSObject

- (NSString*)description {
  return [NSString stringWithFormat:@"<Lookin_PTData: %p (%zu bytes)>", self, length_];
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
