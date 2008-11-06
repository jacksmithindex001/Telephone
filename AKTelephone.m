//
//  AKTelephone.m
//  Telephone
//
//  Copyright (c) 2008 Alexei Kuznetsov. All Rights Reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//  3. The name of the author may not be used to endorse or promote products
//     derived from this software without specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY ALEXEI KUZNETSOV "AS IS" AND ANY EXPRESS
//  OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
//  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
//  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
//  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
//  OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
//  EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import <pjsua-lib/pjsua.h>

#import "AKPreferenceController.h"
#import "AKTelephone.h"
#import "AKTelephoneAccount.h"
#import "AKTelephoneCall.h"
#import "NSString+PJSUA.h"

#define THIS_FILE "AKTelephone.m"

// Ringtones.
#define RINGBACK_FREQ1		440
#define RINGBACK_FREQ2		480
#define RINGBACK_ON			2000
#define RINGBACK_OFF		4000
#define RINGBACK_CNT		1
#define RINGBACK_INTERVAL	4000

NSString *AKTelephoneDidDetectNATNotification = @"AKTelephoneDidDetectNAT";
NSString *AKTelephoneDidUpdateSoundDevicesNotification = @"AKTelephoneDidUpdateSoundDevices";

// Sound device keys
NSString *AKSoundDeviceName = @"AKSoundDeviceName";
NSString *AKSoundDeviceInputCount = @"AKSoundDeviceInputCount";
NSString *AKSoundDeviceOutputCount = @"AKSoundDeviceOutputCount";
NSString *AKSoundDeviceDefaultSamplesPerSecond = @"AKSoundDeviceDefaultSamplesPerSecond";

static AKTelephone *sharedTelephone = nil;

@implementation AKTelephone

@dynamic delegate;
@synthesize accounts;
@dynamic soundDevices;
@synthesize readyState;
@dynamic callData;
@synthesize pjPool;
@synthesize ringbackSlot;
@synthesize ringbackCount;
@synthesize ringbackPort;

- (id)delegate
{
	return delegate;
}

- (void)setDelegate:(id)aDelegate
{
	if (delegate == aDelegate)
		return;
	
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	
	if (delegate != nil)
		[notificationCenter removeObserver:delegate name:nil object:self];
	
	if (aDelegate != nil) {
		if ([aDelegate respondsToSelector:@selector(telephoneDidDetectNAT:)])
			[notificationCenter addObserver:aDelegate
								   selector:@selector(telephoneDidDetectNAT:)
									   name:AKTelephoneDidDetectNATNotification
									 object:self];
		
		if ([aDelegate respondsToSelector:@selector(telephoneDidUpdateSoundDevices:)])
			[notificationCenter addObserver:aDelegate
								   selector:@selector(telephoneDidUpdateSoundDevices:)
									   name:AKTelephoneDidUpdateSoundDevicesNotification
									 object:self];
	}
	
	delegate = aDelegate;
}

- (NSArray *)soundDevices
{
	NSUInteger i, devicesCount;
	devicesCount = pjmedia_snd_get_dev_count();
	if (devicesCount == 0)
		NSLog(@"Error getting sound devices");
	
	NSMutableArray *devices = [NSMutableArray arrayWithCapacity:devicesCount];
	for (i = 0; i < devicesCount; ++i) {
		const pjmedia_snd_dev_info *deviceInfo;
		
		deviceInfo = pjmedia_snd_get_dev_info(i);
		NSAssert(deviceInfo != NULL, @"Could not get sound device info");
		
		NSString *deviceName = [NSString stringWithCString:deviceInfo->name encoding:NSASCIIStringEncoding];
		NSNumber *inputCount = [NSNumber numberWithInt:deviceInfo->input_count];
		NSNumber *outputCount = [NSNumber numberWithInt:deviceInfo->output_count];
		NSNumber *defaultSamplesPerSecond = [NSNumber numberWithInt:deviceInfo->default_samples_per_sec];
		
		NSDictionary *deviceDict = [NSDictionary dictionaryWithObjectsAndKeys:
									deviceName, AKSoundDeviceName,
									inputCount, AKSoundDeviceInputCount,
									outputCount, AKSoundDeviceOutputCount,
									defaultSamplesPerSecond, AKSoundDeviceDefaultSamplesPerSecond,
									nil];
		
		[devices addObject:deviceDict];
	}
	
	return [[devices retain] autorelease];
}

- (AKTelephoneCallData *)callData
{
	return callData;
}


#pragma mark Telephone singleton instance

+ (id)telephoneWithDelegate:(id)aDelegate
{
	@synchronized(self) {
		if (sharedTelephone == nil)
			[[self alloc] initWithDelegate:aDelegate];	// Assignment not done here
	}
	
	return sharedTelephone;
}

+ (id)telephone
{
	return [self telephoneWithDelegate:nil];
}

+ (id)allocWithZone:(NSZone *)zone
{
	@synchronized(self) {
		if (sharedTelephone == nil) {
			sharedTelephone = [super allocWithZone:zone];
			return sharedTelephone;		// Assignment and return on first allocation
		}
	}
	
	return nil;		// On subsequent allocation attempts return nil
}

- (id)copyWithZone:(NSZone *)zone
{
	return self;
}

- (id)retain
{
	return self;
}

- (NSUInteger)retainCount
{
	return UINT_MAX;	// Denotes an object that cannot be released
}

- (void)release
{
	// Do nothing
}

- (id)autorelease
{
	return self;
}


#pragma mark -

+ (AKTelephone *)sharedTelephone
{
	return sharedTelephone;
}

- (id)initWithDelegate:(id)aDelegate
{
	self = [super init];
	if (self == nil)
		return nil;
	
	[self setDelegate:aDelegate];
	accounts = [[NSMutableArray alloc] init];
	
	pjsua_config_default(&userAgentConfig);
	pjsua_logging_config_default(&loggingConfig);
	pjsua_media_config_default(&mediaConfig);
	pjsua_transport_config_default(&transportConfig);
	
	ringbackSlot = PJSUA_INVALID_ID;
	userAgentConfig.max_calls = AKTelephoneCallsMax;
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	NSString *stunServerHost = [defaults stringForKey:AKSTUNServerHost];
	if (stunServerHost != nil)
		userAgentConfig.stun_host = [[NSString stringWithFormat:@"%@:%@",
									  stunServerHost, [defaults objectForKey:AKSTUNServerPort]]
									 pjString];
	
	loggingConfig.log_filename = [[[defaults stringForKey:AKLogFileName]
								   stringByExpandingTildeInPath]
								  pjString];
	loggingConfig.level = [defaults integerForKey:AKLogLevel];
	loggingConfig.console_level = [defaults integerForKey:AKConsoleLogLevel];
	
	mediaConfig.no_vad = ![defaults boolForKey:AKVoiceActivityDetection];
	
	transportConfig.port = [defaults integerForKey:AKTransportPort];
	
	userAgentConfig.cb.on_incoming_call = AKIncomingCallReceived;
	userAgentConfig.cb.on_call_media_state = AKCallMediaStateChanged;
	userAgentConfig.cb.on_call_state = AKCallStateChanged;
	userAgentConfig.cb.on_reg_state = AKTelephoneAccountRegistrationStateChanged;
	userAgentConfig.cb.on_nat_detect = AKTelephoneDetectedNAT;
	
	pj_status_t status;
	
	// Create pjsua.
	status = pjsua_create();
	if (status != PJ_SUCCESS) {
		NSLog(@"Error creating pjsua");
		[self release];
		sharedTelephone = nil;
		return nil;
	}
	// Create pool for pjsua.
	pjPool = pjsua_pool_create("telephone-pjsua", 1000, 1000);
	
	[self setReadyState:AKTelephoneCreated];
	
	// Initialize pjsua.
	status = pjsua_init(&userAgentConfig, &loggingConfig, &mediaConfig);
	if (status != PJ_SUCCESS) {
		NSLog(@"Error initializing pjsua");
		[self release];
		sharedTelephone = nil;
		return nil;
	}
	
	// Create ringback tones.
	unsigned i, samplesPerFrame;
	pjmedia_tone_desc tone[RINGBACK_CNT];
	pj_str_t name;
	
	samplesPerFrame = mediaConfig.audio_frame_ptime *
	mediaConfig.clock_rate *
	mediaConfig.channel_count / 1000;
	
	name = pj_str("ringback");
	status = pjmedia_tonegen_create2(pjPool, &name,
									 mediaConfig.clock_rate,
									 mediaConfig.channel_count,
									 samplesPerFrame, 16, PJMEDIA_TONEGEN_LOOP,
									 &ringbackPort);
	if (status != PJ_SUCCESS) {
		NSLog(@"Error creating ringback tones");
		[self release];
		sharedTelephone = nil;
		return nil;
	}
	
	pj_bzero(&tone, sizeof(tone));
	for (i = 0; i < RINGBACK_CNT; ++i) {
		tone[i].freq1 = RINGBACK_FREQ1;
		tone[i].freq2 = RINGBACK_FREQ2;
		tone[i].on_msec = RINGBACK_ON;
		tone[i].off_msec = RINGBACK_OFF;
	}
	tone[RINGBACK_CNT - 1].off_msec = RINGBACK_INTERVAL;
	
	pjmedia_tonegen_play(ringbackPort, RINGBACK_CNT, tone, PJMEDIA_TONEGEN_LOOP);
	
	status = pjsua_conf_add_port(pjPool, ringbackPort, &ringbackSlot);
	if (status != PJ_SUCCESS) {
		NSLog(@"Error adding media port for ringback tones");
		[self release];
		sharedTelephone = nil;
		return nil;
	}
	
	[self setReadyState:AKTelephoneConfigured];
	
	// Add UDP transport.
	status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transportConfig, NULL);
	if (status != PJ_SUCCESS) {
		NSLog(@"Error creating transport");
		[self release];
		sharedTelephone = nil;
		return nil;
	}
	
	[self setReadyState:AKTelephoneTransportCreated];
	
	return self;
}

- (id)init
{
	return [self initWithDelegate:nil];
}

- (void)dealloc
{
	[accounts release];
	
	[super dealloc];
}


#pragma mark -

- (BOOL)start
{	
	pj_status_t status = pjsua_start();
	if (status != PJ_SUCCESS)
		return NO;
	
	[self setReadyState:AKTelephoneStarted];
	
	return YES;
}

- (BOOL)addAccount:(AKTelephoneAccount *)anAccount withPassword:(NSString *)aPassword
{
	pjsua_acc_config accountConfig;
	pjsua_acc_config_default(&accountConfig);
	
	NSString *fullSIPURL = [NSString stringWithFormat:@"%@ <sip:%@>", [anAccount fullName], [anAccount SIPAddress]];
	accountConfig.id = [fullSIPURL pjString];
	
	NSString *registerURI = [NSString stringWithFormat:@"sip:%@", [anAccount registrar]];
	accountConfig.reg_uri = [registerURI pjString];
	
	accountConfig.cred_count = 1;
	accountConfig.cred_info[0].realm = pj_str("*");
	accountConfig.cred_info[0].scheme = pj_str("digest");
	accountConfig.cred_info[0].username = [[anAccount username] pjString];
	accountConfig.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
	accountConfig.cred_info[0].data = [aPassword pjString];
	
	pjsua_acc_id accountIdentifier;
	pj_status_t status = pjsua_acc_add(&accountConfig, PJ_FALSE, &accountIdentifier);
	if (status != PJ_SUCCESS) {
		NSLog(@"Error adding account %@ with status %d", anAccount, status);
		return NO;
	}
	
	[anAccount setIdentifier:accountIdentifier];
	
	[[self accounts] addObject:anAccount];
	
	[anAccount setOnline:YES];
	
	return YES;
}

- (BOOL)removeAccount:(AKTelephoneAccount *)anAccount
{
	pj_status_t status = pjsua_acc_del([anAccount identifier]);
	if (status != PJ_SUCCESS)
		return NO;
	
	NSLog(@"Removing account %@ with id %d", anAccount, [anAccount identifier]);
	[[self accounts] removeObject:anAccount];
	
	return YES;
}

- (AKTelephoneAccount *)accountByIdentifier:(NSInteger)anIdentifier
{
	for (AKTelephoneAccount *anAccount in [self accounts])
		if ([anAccount identifier] == anIdentifier)
			return [[anAccount retain] autorelease];
	
	return nil;
}

- (AKTelephoneCall *)telephoneCallByIdentifier:(NSInteger)anIdentifier
{
	for (AKTelephoneAccount *anAccount in [self accounts])
		for (AKTelephoneCall *aCall in [anAccount calls])
			if ([aCall identifier] == anIdentifier)
				return [[aCall retain] autorelease];
	
	return nil;
}

- (void)hangUpAllCalls
{
	pjsua_call_hangup_all();
}

- (BOOL)setSoundInputDevice:(NSInteger)input soundOutputDevice:(NSInteger)output
{
	NSInteger soundInputDevice, soundOutputDevice;
	pjsua_get_snd_dev(&soundInputDevice, &soundOutputDevice);
	if (soundInputDevice == input && soundOutputDevice == output)
		return YES;
	
	NSArray *devices = [self soundDevices];
	NSInteger i;
	
	if (input < 0 || input == NSNotFound) {
		// Determine first matched sound input device.
		for (i = 0; i < [devices count]; ++i)
			if ([[[devices objectAtIndex:i] objectForKey:AKSoundDeviceInputCount] integerValue] > 0) {
				input = i;
				break;
			}
	}
	
	if (output < 0 || output == NSNotFound) {
		// Determine first matched sound output device.
		for (i = 0; i < [devices count]; ++i)
			if ([[[devices objectAtIndex:i] objectForKey:AKSoundDeviceOutputCount] integerValue] > 0) {
				output = i;
				break;
			}
	}
	
	NSLog(@"Setting sound devices to %d, %d", input, output);
	pj_status_t status = pjsua_set_snd_dev(input, output);
	
	return (status == PJ_SUCCESS) ? YES : NO;
}

// This method will leave application silent.
// setSoundInputDevice:soundOutputDevice: must be called explicitly after calling this method to enable sound IO.
// Usually, application controller is responsible of sending setSoundInputDevice:soundOutputDevice: to set sound IO after this method is called.
// Posts AKTelephoneDidUpdateSoundDevicesNotification asynchronously.
- (void)updateSoundDevices
{	
	// Stop sound device and disconnect it from the conference.
	pjsua_set_null_snd_dev();
	
	// Reinit sound device.
	pjmedia_snd_deinit();
	pjmedia_snd_init(pjsua_get_pool_factory());
	
	// Post notification asynchronously.
	NSNotification *notification =
	[NSNotification notificationWithName:AKTelephoneDidUpdateSoundDevicesNotification
								  object:self];
	[[NSNotificationQueue defaultQueue] enqueueNotification:notification
											   postingStyle:NSPostWhenIdle];
}

- (BOOL)destroyUserAgent
{
	// Close ringback port.
	if (ringbackPort != NULL &&
		ringbackSlot != PJSUA_INVALID_ID)
	{
		pjsua_conf_remove_port(ringbackSlot);
		ringbackSlot = PJSUA_INVALID_ID;
		pjmedia_port_destroy(ringbackPort);
		ringbackPort = NULL;
	}
	
	if (pjPool != NULL) {
		pj_pool_release(pjPool);
		pjPool = NULL;
	}
	
	pj_status_t status;
	status = pjsua_destroy();
	
	return (status == PJ_SUCCESS) ? YES : NO;
}

@end


void AKTelephoneDetectedNAT(const pj_stun_nat_detect_result *result)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	if (result->status != PJ_SUCCESS)
		pjsua_perror(THIS_FILE, "NAT detection failed", result->status);
	else {
		PJ_LOG(3, (THIS_FILE, "NAT detected as %s", result->nat_type_name));
		[[NSNotificationCenter defaultCenter] postNotificationName:AKTelephoneDidDetectNATNotification
															object:[AKTelephone sharedTelephone]];
	}
	
	[pool release];
}
