//
//  main.m
//  CARecorder
//
//  Created by Moses Lee on 3/6/16.
//  Copyright © 2016 Moses Lee. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>

#define kNumberRecordBuffers 5     //You can use more than 3 but less than 3 can be problematic

#pragma mark user data struct
//User info struct
typedef struct MyRecorder{
    AudioFileID recordFile;     //File to write to
    SInt64      recordPacket;   //Index of the stream of packet that its writing
    Boolean     running;        //Boolean flag TRUE if recording false if not recording
} MyRecorder;

#pragma mark utility functions
//CheckError function to see OSStatus values
//THIS IS A SUPER IMPORTANT FUNCTION
static void CheckError(OSStatus error, const char * operation)
{
    //If no error just return
    if (error == noErr) return;
    
    char errorString[20];
    
    //See if it appears to be a 4 char code
    //Write it to errorString[1-4]
    *(UInt32 *) (errorString + 1) = CFSwapInt32HostToBig(error);
    
    //Use C library isprint function to see if bytes are printable char
    //If errorString[1-4] are all printable, than print the error
    if(isprint(errorString[1]) && isprint(errorString[2]) &&
       isprint(errorString[3]) && isprint(errorString[4])){
        
        //Single quotes at beginning and end of string
        errorString[0] = errorString[5] = '\'';
        
        //Null terminating character
        errorString[6] = '\0';
    } else {
        //If any of the errorString[1-4] is not printable char, format it as integer
        sprintf(errorString, "%d", (int) error);
    }
    
    //Print out the error
    fprintf(stderr, "Error: %s (%s)\n", operation , errorString);
    
    //Exit the application
    //Maybe for my library we should not just exit, but throw an exception or something
    exit(1);
}

//Gets the input device's default sample rate
OSStatus MyGetDefaultInputDeviceSampleRate(Float64 * outSampleRate)
{
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    //Struct for propertyAddress
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    
    /*
     Non-deprecated way
     Get property data. In this case I want the device ID
     1st param: the type of object
     2nd param: the property address struct. Specifies what the property I want and the scope of that property
     3rd param: 0 for now
     4th param: NULL for now
     5th param: size of the property you want to get, in this case AudioDeviceID
     6th param: the property you want. In this case the device id for the specified input device
     */
    error = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                       &propertyAddress,
                                       0,
                                       NULL,
                                       &propertySize,
                                       &deviceID);
    
//    This is the book's way, but this is depcreated in 10.11
//    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject,
//                                       &propertyAddress,
//                                       0,
//                                       NULL,
//                                       &propertySize,
//                                       &deviceID);
    
    if(error) return error;
    
    
    printf("Got device ID: %d\n", deviceID);
    
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope   = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    
    propertySize = sizeof(Float64);
    
    /*
     Non-deprecated way
     Get property data. In this case I want the sample rate of the deviceID i am passing in
     1st param: the type of object. in this case I want the device of the deviceID
     2nd param: the property address struct. Specifies what the property I want and the scope of that property
     3rd param: 0 for now
     4th param: NULL for now
     5th param: size of the property you want to get, in this case a float value
     6th param: the property you want. in this case the sample rate of the specified device
     */
    error = AudioObjectGetPropertyData(deviceID,
                                       &propertyAddress,
                                       0,
                                       NULL,
                                       &propertySize,
                                       outSampleRate);
    
//    This is the book's way, but this is depcreated in 10.11
//    error = AudioHardwareServiceGetPropertyData(deviceID,
//                                                &propertyAddress,
//                                                0,
//                                                NULL,
//                                                &propertySize,
//                                                outSampleRate);
    
    return error;
}


//Gets the buffer size based on format
static int MyComputeRecordBufferSize(const AudioStreamBasicDescription * format,
                                     AudioQueueRef queue,
                                     float seconds)
{
    int packets, frames, bytes;
    
    /*
     Need to know how many frames.
     This is for one channel
     */
    frames = (int) ceil(seconds * format->mSampleRate);
    
    /*
     If mBytesPerFrame already declared than get the needed
     byte count by multiplying number of frames by bytes per frame
    */
    if(format->mBytesPerFrame > 0)
        bytes = frames * format->mBytesPerFrame;
    else //If mBytesPerFrame not set, then work at packet level
    {
        
        UInt32 maxPacketSize;
        /*
         If packet size is constant, the mBytesPerPacket will be greater than 0
        */
        if(format->mBytesPerPacket > 0)
            maxPacketSize = format->mBytesPerPacket;
        else //Actually have to query for the packet size
        {
            //Get the largest single packet size possible
            UInt32 propertySize = sizeof(maxPacketSize);
            
            /*
             Gets the property specified from the queue
             1st param: the queue in question
             2nd param: What property do you want
             3rd param: the property to fill
             4th param: the size of that property
             */
            CheckError(AudioQueueGetProperty(queue,
                                             kAudioConverterPropertyMaximumOutputPacketSize,
                                             &maxPacketSize,
                                             &propertySize),
                       "Couldn't get queue's maximum output packet size");
        }
        
        /*
         Determine the number of packets present.
         If mFramesPerPacket is set then divide frames by mFramesPerPacket to get
         number of packets
         */
        if(format->mFramesPerPacket > 0)
        {
            packets = frames / format->mFramesPerPacket;
        }
        else
        {
            //Worse case scenario: 1 frame in a packet
            packets = frames;
        }
        
        //Sanity check. It always pays to play it safe
        if(packets == 0)
            packets = 1;
        
        //Bytes to get
        bytes = packets * maxPacketSize;
    }
    
    return bytes;
}

//Get the magic cookie for data verification
static void MyCopyEncoderCookieToFile(AudioQueueRef queue,
                                      AudioFileID theFile)
{
    OSStatus error;
    UInt32 propertySize;
    
    /*
     Gets the property size of one of the queue attributes
     1st param: the queue in question
     2nd param: the property to get
     3rd param: the property size of that property
     */
    error = AudioQueueGetPropertySize(queue,
                                      kAudioConverterCompressionMagicCookie,
                                      &propertySize);
    
    /*
     If size is 0 than no magic cookie needs to be written
     */
    if(error == noErr && propertySize > 0)
    {
        //Allocate property size of memory
        Byte * magicCookie = (Byte *) malloc(propertySize);
        
        /*
         Get a property from the queue
         1st param: queue in question
         2nd param: what property to get
         3rd param: the property
         4th param: the property size
         */
        CheckError(AudioQueueGetProperty(queue,
                                         kAudioQueueProperty_MagicCookie,
                                         magicCookie,
                                         &propertySize),
                   "Couldn't get audio queue's magic cookie");
        
        /*
         Set the property to the audio file
         1st param: the file to set the property to
         2nd param: what property you are setting
         3rd param: the size of the property that you are setting
         4th param: the property to set
         */
        CheckError(AudioFileSetProperty(theFile,
                                        kAudioFilePropertyMagicCookieData,
                                        propertySize,
                                        magicCookie),
                   "Couldn't set the audio file's magic cookie");
        
        //You used malloc so free the damn thing
        free(magicCookie);
    }
}

//This is just my own metering function
static void outputMeteringLevels(AudioQueueRef inQueue,
                                 AudioStreamBasicDescription inFormat)
{
    //Get the size of how many meters to read from
    //AudioQueueLevelMeterState is a struct
    UInt32 dataSize = sizeof(AudioQueueLevelMeterState) * inFormat.mChannelsPerFrame;
    
    //Allocate dataSize amount of bytes
    AudioQueueLevelMeterState * decibalLevels = (AudioQueueLevelMeterState *) malloc(dataSize);
    AudioQueueLevelMeterState * rawLevels     = (AudioQueueLevelMeterState *) malloc(dataSize);
    
    OSStatus dBerror  = AudioQueueGetProperty(inQueue,
                                              kAudioQueueProperty_CurrentLevelMeterDB,
                                              decibalLevels,
                                              &dataSize);
    OSStatus rawError = AudioQueueGetProperty(inQueue,
                                              kAudioQueueProperty_CurrentLevelMeter,
                                              rawLevels,
                                              &dataSize);
    if(dBerror || rawError) {
        printf("Could not get metering\n");
    } else {
        printf("decibal: ");
        for (int i = 0; i < inFormat.mChannelsPerFrame; i++) {
            printf(" %f ", decibalLevels[i].mPeakPower);
        }
        
        printf("--- raw values: ");
        for(int i = 0; i < inFormat.mChannelsPerFrame; i++){
            printf(" %f ", rawLevels[i].mPeakPower);
        }
        printf("\n");
    }
    
    free(decibalLevels);
    free(rawLevels);
}

#pragma mark record callback functions

static void MyAQInputCallback(void * inUserData,
                              AudioQueueRef inQueue,
                              AudioQueueBufferRef inBuffer,
                              const AudioTimeStamp * inStartTime,
                              UInt32 inNumPackets,
                              const AudioStreamPacketDescription * inPacketDesc)
{
    /*
     Remember when you registered MyRecorder struct in main?
     inUserData is pointing to that
    */
    MyRecorder * recorder = (MyRecorder *) inUserData;
    
    
    if(inNumPackets > 0)
    {
        /*
         Write packets to the specified file
         1st param: the file to write to. Type AudioFileID
         2nd param: 
         3rd param: the buffer byte size
         4th param:
         5th param:
         6th param:
         7th param:
         */
        CheckError(AudioFileWritePackets(recorder->recordFile,
                                         FALSE,
                                         inBuffer->mAudioDataByteSize,
                                         inPacketDesc,
                                         recorder->recordPacket,
                                         &inNumPackets,
                                         inBuffer->mAudioData),
                   "AudioFileWritePackets failed");
        
        recorder->recordPacket += inNumPackets;
    }
    
    /*
     If recorder is still set to run, enqueue the next buffer
     */
    if(recorder->running)
        /*
         Enqueue the next buffer
         1st param: the reference queue to enqueue this buffer to
         2nd param: the reference buffer to be enqueued
         3rd param: 0 because we are recording input, look at documentation for more
         4th param: NULL because we are recording input, look at documentation for more
         */
        CheckError(AudioQueueEnqueueBuffer(inQueue,
                                           inBuffer,
                                           0,
                                           NULL),
                   "AudioQueueEnqueueBuffer failed");
}

#pragma mark main function
int main(int argc, const char * argv[]) {
    //Set up format
    MyRecorder recorder = {0};                          //Recorder instance
    AudioStreamBasicDescription recordFormat;           //Recorded file format
    memset(&recordFormat, 0, sizeof(recordFormat));     //0 this biznatch out
    
    
    //Set the file format to be MPEG4AAC and stereo (2)
    /*
     For encoded format this is all you need to do:
     1. set the desired audio format
     2. set the channels per frame (1 for mono, 2 for stereo, etc)
     3. Set the sample rate
     4. Let core audio do all the filling through AudioFormatGetProperty
     */
    recordFormat.mFormatID = kAudioFormatMPEG4AAC;
    recordFormat.mChannelsPerFrame = 2;
    
    //Set up sample rate from the device's sample rate
    CheckError(MyGetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate),
               "Could not get Sample Rate");
    
    //Filling in ASBD with AudioFormatGetProperty
    //Letting core audio fill the details of this format
    UInt32 propSize = sizeof(recordFormat);
    CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                      0,
                                      NULL,
                                      &propSize,
                                      &recordFormat),
               "AudioFormatGetProperty failed");
    
    
    //Set up queue
    //AudioQueueRef is a typedef pointer to a struct OpaqueAudioQueue
    AudioQueueRef queue = {0};
    
    /*
     Essentially creates the queue and gives us a reference
     1st param: Takes in a format to record into. A type AudioStreamBasicDescription
     2nd param: Takes in a pointer to a function that has parameter requirements (Look at documentation)
     3rd param: a pointer to the with user data to be used in the call back function
     4th param: NULL for now (loop behaviour)
     5th param: NULL for now (loop behaviour)
     6th param: A flag value that is always 0
     7th param: Pointer to the reference AudioQueueRef
     Side effect: Fills in the rest of recordFormat struct for encoding etc.
     */
    CheckError(AudioQueueNewInput(&recordFormat,
                                  MyAQInputCallback,
                                  &recorder,
                                  NULL,
                                  NULL,
                                  0,
                                  &queue),
               "AudioQueueNewInput failed");
    
    /*
     Retrieve Filled-Out ASBD
     1st param: the queue to get the properties from
     2nd param: The type property we want to get
     3rd param: AudioStreamBasicDescription struct
     4th param: size of the struct
     */
    UInt32 size = sizeof(recordFormat);
    CheckError(AudioQueueGetProperty(queue,
                                     kAudioConverterCurrentOutputStreamDescription,
                                     &recordFormat,
                                     &size),
               "Couldn't get queue's format");
    
    //Set up file
    CFURLRef myFileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                       CFSTR("output.caf"),
                                                       kCFURLPOSIXPathStyle,
                                                       false);
    
    //Create the AudioFile
    CheckError(AudioFileCreateWithURL(myFileURL,
                                      kAudioFileCAFType,
                                      &recordFormat,
                                      kAudioFileFlags_EraseFile,
                                      &recorder.recordFile),
               "AudioFileCreateWithURL failed");
    
    CFRelease(myFileURL);
    
    //Deal with cookies
    MyCopyEncoderCookieToFile(queue, recorder.recordFile);
    
    //Other set up
    //Determine buffer byte size
    int bufferByteSize = MyComputeRecordBufferSize(&recordFormat, queue, 0.5);
    printf("BufferByteSize %d\n", bufferByteSize);
    
    //Initialize kNumberRecordBuffers amount of Buffers and add them to the AudioQueue
    int bufferIndex;
    for(bufferIndex = 0; bufferIndex < kNumberRecordBuffers; bufferIndex++){
        //typdeffed pointer to a AudioQueueBuffer
        AudioQueueBufferRef buffer;
        
        /*
         Allocate buffers --- MINIMUM HAS TO BE 3
         1st param: the queue to own this buffer to
         2nd param: the byte size of the buffer
         3rd param: a reference to the buffer being allocated
         */
        CheckError(AudioQueueAllocateBuffer(queue,
                                            bufferByteSize,
                                            &buffer),
                   "AudioQueueAllocateBuffer failed");
        
        /*
         Add the buffer to the queue
         1st param: The queue to enqueue this buffer to
         2nd param: the reference to the buffer created above
         3rd param: 0 because we are recording input, look at documentation for more
         4th param: NULL because we are recording input, look at documentation for more
         */
        CheckError(AudioQueueEnqueueBuffer(queue,
                                           buffer,
                                           0,
                                           NULL),
                   "AudioQueueEnqueueBuffer failed");

    }
    
    /*Enable metering*/
    UInt32 val = 1;
    /*
     1st param: the queue to set the property
     2nd param: what property to set
     3rd param: just a flag UInt32 is good
     4th param: size of flag
     */
    CheckError(AudioQueueSetProperty(queue,
                                     kAudioQueueProperty_EnableLevelMetering,
                                     &val,
                                     sizeof(UInt32)),
               "Could not set metering");
    
    //Start the audio queue
    recorder.running = TRUE;
    /*
     Starts the queue
     1st param: the queue to start
     2nd param: NULL to say start ASAP. Documentation has more options
     */
    CheckError(AudioQueueStart(queue,
                               NULL),
               "AudioQueueStart failed");
    
    
    /*This is for metering in a separate thread*/
    //TODO look more into grand central dispatch
    /*
     This block is to enable metering in a separate thread. Will have to expand on this later
     when I have more experience with Grand Central Dispatch
     */
    dispatch_queue_t timerQueue = dispatch_queue_create("com.firm.app.timer", 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timerQueue);
    /*
     Set a timer for the thread
     1st param: the dispatch_queue_t thread 
     2nd param: start time
     3rd param: interval
     4th param: leeway
     */
    dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), .5 * NSEC_PER_SEC, .5 * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(timer, ^{
        outputMeteringLevels(queue, recordFormat);
    });
    
    dispatch_resume(timer);

    /*End of my thread timer*/

    
    //Just user interactive shiznat
    printf("Recording, press <return> to stop: \n");
    getchar();
    
    
    
    //Stop the audio Queue
    printf(" * recording complete *\n");
    recorder.running = FALSE;
    
    //Stop the threaded timer
    dispatch_suspend(timer);
    
    /*
     Stops the queue
     1st param: queue to be stopped
     2nd param: TRUE if stop immediately, FALSE if wait until all buffers cleared
     */
    CheckError(AudioQueueStop(queue,
                              FALSE),
               "AudioQueueStop failed");
    
    //Deal with magic cookies. Think its here to verify data
    MyCopyEncoderCookieToFile(queue, recorder.recordFile);
    
    AudioQueueDispose(queue, TRUE);
    AudioFileClose(recorder.recordFile);
    
    return 0;
}







//


//
