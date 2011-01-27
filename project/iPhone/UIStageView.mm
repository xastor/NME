//
//  UIStageView.mm
//  Blank
//
//  Created by Hugh on 12/01/10.
//  Copyright __MyCompanyName__ 2010. All rights reserved.
//


#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <Display.h>
#include <Surface.h>
#include <KeyCodes.h>

#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>


using namespace nme;

void EnableKeyboard(bool inEnable);
extern "C" void nme_app_set_active(bool inActive);


@interface NMEAppDelegate : NSObject <UIApplicationDelegate>
{
    UIWindow *window;
    UIViewController *controller;
}
@property (nonatomic, retain) IBOutlet UIWindow *window;
@property (nonatomic, retain) IBOutlet UIViewController *controller;
@end


@interface UIStageViewController : UIViewController
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation;
- (void)loadView;
@end


// This class wraps the CAEAGLLayer from CoreAnimation into a convenient UIView subclass.
// The view content is basically an EAGL surface you render your OpenGL scene into.
// Note that setting the view non-opaque will only work if the EAGL surface has an alpha channel.
@interface UIStageView : UIView<UITextFieldDelegate,UIAccelerometerDelegate>
{    
@private
   BOOL animating;
   BOOL displayLinkSupported;
   id displayLink;
   NSInteger animationFrameInterval;
   NSTimer *animationTimer;
   int    mPrimaryEvent;
@public
   class EAGLStage *mStage;

   UITextField *mTextField;
   UIAccelerometer *mAccelerometer;
   double mAccX;
   double mAccY;
   double mAccZ;
   BOOL mKeyboardEnabled;
   bool   mMultiTouch;
   int    mPrimaryTouchHash;
}


@property (readonly, nonatomic, getter=isAnimating) BOOL animating;
@property (nonatomic) NSInteger animationFrameInterval;

- (void) myInit;
- (void) startAnimation;
- (void) stopAnimation;
- (void) drawView:(id)sender;
- (void) onPoll:(id)sender;
- (void) enableKeyboard:(bool)withEnable;
- (void) enableMultitouch:(bool)withEnable;
- (BOOL)canBecomeFirstResponder;
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event;

@end

// Global instance ...
UIStageView *sgMainView = nil;
static FrameCreationCallback sOnFrame = nil;

// --- Stage Implementaton ------------------------------------------------------

class EAGLStage : public nme::Stage
{
public:
   EAGLStage(CAEAGLLayer *inLayer,bool inInitRef) : nme::Stage(inInitRef)
   {
      defaultFramebuffer = 0;
      colorRenderbuffer = 0;
      mHardwareContext = 0;
      mHardwareSurface = 0;
      mLayer = inLayer;
      mDPIScale = 1.0;
      mContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
        
      if (!mContext || ![EAGLContext setCurrentContext:mContext])
      {
         throw "Could not initilize OpenL";
      }
 
      CreateFramebuffer();
      
      mHardwareContext = HardwareContext::CreateOpenGL(inLayer,mContext);
      mHardwareContext->IncRef();
      mHardwareSurface = new HardwareSurface(mHardwareContext);
      mHardwareSurface->IncRef();
   }

   double getDPIScale() { return mDPIScale; }


   ~EAGLStage()
   {
      if (mHardwareSurface)
         mHardwareSurface->DecRef();
      if (mHardwareContext)
         mHardwareContext->DecRef();
      // Tear down GL
      if (defaultFramebuffer)
      {
         glDeleteFramebuffersOES(1, &defaultFramebuffer);
         defaultFramebuffer = 0;
      }

      if (colorRenderbuffer)
      {
         glDeleteRenderbuffersOES(1, &colorRenderbuffer);
         colorRenderbuffer = 0;
      }
   
      // Tear down context
      if ([EAGLContext currentContext] == mContext)
         [EAGLContext setCurrentContext:nil];
   
      [mContext release];
   }

   bool getMultitouchSupported() { return true; }

   void setMultitouchActive(bool inActive)
   {
      [ sgMainView enableMultitouch:inActive ];

   }
   bool getMultitouchActive()
   {
      return sgMainView->mMultiTouch;
   }



   bool isOpenGL() const { return true; }


   void CreateFramebuffer()
   {
      // Create default framebuffer object.
      // The backing will be allocated for the current layer in -resizeFromLayer
      glGenFramebuffersOES(1, &defaultFramebuffer);
      glGenRenderbuffersOES(1, &colorRenderbuffer);
      glBindFramebufferOES(GL_FRAMEBUFFER_OES, defaultFramebuffer);
      glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer);
      [mContext renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer*)mLayer];
      glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES,
                                  GL_RENDERBUFFER_OES, colorRenderbuffer);
   
      glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
      glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);

      //printf("Create OGL window %dx%d\n", backingWidth, backingHeight);
       
      if (glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES)
      {
         NSLog(@"Failed to make complete framebuffer object %x",
              glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
         throw "OpenGL resize failed";
      }
   }
   
   
  void DestroyFramebuffer()
   {
      if (defaultFramebuffer)
         glDeleteFramebuffersOES(1, &defaultFramebuffer);
      defaultFramebuffer = 0;
      if (colorRenderbuffer)
         glDeleteRenderbuffersOES(1, &colorRenderbuffer);
      defaultFramebuffer = 0;
   }
   

   void OnResizeLayer(CAEAGLLayer *inLayer)
   {   
      // Recreate frame buffers ..
      [EAGLContext setCurrentContext:mContext];
      DestroyFramebuffer();
      CreateFramebuffer();

      mHardwareContext->SetWindowSize(backingWidth,backingHeight);

      //printf("OnResizeLayer %dx%d\n", backingWidth, backingHeight);
      Event evt(etResize);
      evt.x = backingWidth;
      evt.y = backingHeight;
      HandleEvent(evt);

   }

   void OnRedraw()
   {
      Event evt(etRedraw);
      HandleEvent(evt);
   }

   void OnPoll()
   {
      Event evt(etPoll);
      HandleEvent(evt);
   }

   void OnEvent(Event &inEvt)
   {
      HandleEvent(inEvt);
   }



   void Flip()
   {
       glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer);
       [mContext presentRenderbuffer:GL_RENDERBUFFER_OES];
   }
   void GetMouse()
   {
      // TODO
   }

   
   Surface *GetPrimarySurface()
   {
      return mHardwareSurface;
   }

   void SetCursor(nme::Cursor)
   {
      // No cursors on iPhone !
   }

   void EnablePopupKeyboard(bool inEnable)
   {
      ::EnableKeyboard(inEnable);
   }



  // --- IRenderTarget Interface ------------------------------------------
   int Width() { return backingWidth; }
   int Height() { return backingHeight; }


   EventHandler mHandler;
   void *mHandlerData;


   EAGLContext *mContext;
   CAEAGLLayer *mLayer;
   HardwareSurface *mHardwareSurface;
   HardwareContext *mHardwareContext;


   // The pixel dimensions of the CAEAGLLayer
   GLint backingWidth;
   GLint backingHeight;
   double mDPIScale;
   
   // The OpenGL names for the framebuffer and renderbuffer used to render to this view
   GLuint defaultFramebuffer, colorRenderbuffer;

};


// --- UIStageViewController ----------------------------------------------------------

@implementation UIStageViewController

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
   Event evt(etShouldRotate);
   evt.value = interfaceOrientation;
   sgMainView->mStage->OnEvent(evt);

   return evt.result == 2;
}


- (void)loadView
{
   UIStageView *view = [[UIStageView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
   self.view = view;
   //[view release];
}
- (void)dealloc
{
    [super dealloc];
}

@end




// --- UIStageView -------------------------------------------------------------------

@implementation UIStageView

@synthesize animating;
@dynamic animationFrameInterval;

// You must implement this method
+ (Class) layerClass
{
    return [CAEAGLLayer class];
}

//The GL view is stored in the nib file. When it's unarchived it's sent -initWithCoder:

- (id) initWithCoder:(NSCoder*)coder
{    
   if ((self = [super initWithCoder:coder]))
   {
      sgMainView = self;
      [self myInit];
      return self;
   }
   return nil;
}

// For when we init programatically...
- (id) initWithFrame:(CGRect)frame
{    
   if ((self = [super initWithFrame:frame]))
   {
      sgMainView = self;
      self.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleHeight;
      [self myInit];
      return self;
   }
   return nil;
}


- (void) myInit
{
      // Get the layer
      CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;

      eaglLayer.opaque = TRUE;
      eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSNumber numberWithBool:FALSE], kEAGLDrawablePropertyRetainedBacking,
                                      kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                      nil];

      mStage = new EAGLStage(eaglLayer,true);

		self.contentScaleFactor = mStage->getDPIScale();

      // Set scaling to ensure 1:1 pixels ...
      if([[UIScreen mainScreen] respondsToSelector: NSSelectorFromString(@"scale")])
      {
	      if([self respondsToSelector: NSSelectorFromString(@"contentScaleFactor")])
	      {
		      mStage->mDPIScale = [[UIScreen mainScreen] scale];
            printf("Using DPI scale %f\n", mStage->mDPIScale);
		      self.contentScaleFactor = mStage->mDPIScale;
	      }
      }

  
      mAccelerometer = [UIAccelerometer sharedAccelerometer];
      mAccelerometer.updateInterval = 0.033;
      mAccelerometer.delegate = self;
     
      mAccX = 0.0;
      mAccY = -1.0;
      mAccZ = 0.0;
      animating = FALSE;
      displayLinkSupported = FALSE;
      animationFrameInterval = 1;
      displayLink = nil;
      animationTimer = nil;
      mTextField = nil;
      mKeyboardEnabled = NO;
      
      mMultiTouch = false;
      mPrimaryTouchHash = 0;


      // A system version of 3.1 or greater is required to use CADisplayLink. The NSTimer
      // class is used as fallback when it isn't available.
      /*
      NSString *reqSysVer = @"3.1";
      NSString *currSysVer = [[UIDevice currentDevice] systemVersion];
      if ([currSysVer compare:reqSysVer options:NSNumericSearch] != NSOrderedAscending)
         displayLinkSupported = TRUE;
      */

      displayLinkSupported = FALSE;


      Event evt(etResize);
      evt.x = mStage->Width();
      evt.y = mStage->Height();
      mStage->HandleEvent(evt);
}

- (void)accelerometer:(UIAccelerometer *)accelerometer didAccelerate:(UIAcceleration *)acceleration {
   mAccX = acceleration.x;
   mAccY = acceleration.y;
   mAccZ = acceleration.z;
}


- (BOOL)canBecomeFirstResponder { return YES; }


/* UITextFieldDelegate method.  Invoked when user types something. */

- (BOOL)textField:(UITextField *)_textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {

   if ([string length] == 0)
   {
      /* SDL hack to detect delete */
      Event key_down(etKeyDown);
      key_down.value = keyBACKSPACE;
      mStage->OnEvent(key_down);

      Event key_up(etKeyDown);
      key_up.value = keyBACKSPACE;
      mStage->OnEvent(key_up);
   }
   else
   {
      /* go through all the characters in the string we've been sent
         and convert them to key presses */
      for(int i=0; i<[string length]; i++)
      {
         unichar c = [string characterAtIndex: i];

         Event key_down(etKeyDown);
         key_down.code = c;
         mStage->OnEvent(key_down);
         
         Event key_up(etKeyUp);
         key_up.code = c;
         mStage->OnEvent(key_up);
      }
   }

   return NO; /* don't allow the edit! (keep placeholder text there) */
}

/* Terminates the editing session */
- (BOOL)textFieldShouldReturn:(UITextField*)_textField {
   if (mStage->FinishEditOnEnter())
   {
      mStage->SetFocusObject(0);
      [self enableKeyboard:NO];
      return YES;
   }

   // Fake a return character...

   Event key_down(etKeyDown);
   key_down.value = keyENTER;
   key_down.code = '\n';
   mStage->OnEvent(key_down);

   Event key_up(etKeyDown);
   key_up.value = keyENTER;
   key_down.code = '\n';
   mStage->OnEvent(key_up);
 
   return NO;
}



- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
   NSArray *touchArr = [touches allObjects];
   NSInteger touchCnt = [touchArr count];

   for(int i=0;i<touchCnt;i++)
   {
      UITouch *aTouch = [touchArr objectAtIndex:i];

      CGPoint thumbPoint;
      thumbPoint = [aTouch locationInView:aTouch.view];
      //printf("touchesBegan %d x %d!\n", (int)thumbPoint.x, (int)thumbPoint.y);

      if (mPrimaryTouchHash==0)
         mPrimaryTouchHash = [aTouch hash];

      if(aTouch.tapCount==1)
      {
         Event mouse(etMouseClick, thumbPoint.x, thumbPoint.y);
         mStage->OnEvent(mouse);
      }

      if (mMultiTouch)
      {
         Event mouse(etTouchBegin, thumbPoint.x, thumbPoint.y);
         mouse.value = [aTouch hash];
         mStage->OnEvent(mouse);
      }
      else
      {
         Event mouse(etMouseDown, thumbPoint.x, thumbPoint.y);
         mouse.flags |= efLeftDown;
         mouse.flags |= efPrimaryTouch;
         mStage->OnEvent(mouse);
      }

   }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
   NSArray *touchArr = [touches allObjects];
   NSInteger touchCnt = [touchArr count];

   for(int i=0;i<touchCnt;i++)
   {
      UITouch *aTouch = [touchArr objectAtIndex:i];

      CGPoint thumbPoint;
      thumbPoint = [aTouch locationInView:aTouch.view];

      if (mMultiTouch)
      {
         Event mouse(etTouchMove, thumbPoint.x, thumbPoint.y);
         mouse.value = [aTouch hash];
         if (mouse.value==mPrimaryTouchHash)
            mouse.flags |= efPrimaryTouch;
         mStage->OnEvent(mouse);
      }
      else
      {
         Event mouse(etMouseMove, thumbPoint.x, thumbPoint.y);
         mouse.flags |= efLeftDown;
         mouse.flags |= efPrimaryTouch;
         mStage->OnEvent(mouse);
      }
   }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
   NSArray *touchArr = [touches allObjects];
   NSInteger touchCnt = [touchArr count];

   for(int i=0;i<touchCnt;i++)
   {
      UITouch *aTouch = [touchArr objectAtIndex:i];

      CGPoint thumbPoint;
      thumbPoint = [aTouch locationInView:aTouch.view];


      if (mMultiTouch)
      {
         Event mouse(etTouchEnd, thumbPoint.x, thumbPoint.y);
         mouse.value = [aTouch hash];
         if (mouse.value==mPrimaryTouchHash)
         {
            mouse.flags |= efPrimaryTouch;
            mPrimaryTouchHash = 0;
         }
         mStage->OnEvent(mouse);
      }
      else
      {
         Event mouse(etMouseUp, thumbPoint.x, thumbPoint.y);
         mouse.flags |= efPrimaryTouch;
         mStage->OnEvent(mouse);
      }
   }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
   [self touchesEnded:touches withEvent:event];
}

- (void) enableMultitouch:(bool)withEnable
{
   mMultiTouch = withEnable;
   if (mMultiTouch)
      [self setMultipleTouchEnabled:YES];
   else
      [self setMultipleTouchEnabled:NO];
}


- (void) enableKeyboard:(bool)withEnable
{
   if (mKeyboardEnabled!=withEnable)
   {
       mKeyboardEnabled = withEnable;
       if (mKeyboardEnabled)
       {
          // Setup a dummy textfield to make iPhone think we have a text field - but
          //  delegate all the events to ourselves..
          if (mTextField==nil)
          {
             mTextField = [[[UITextField alloc] initWithFrame: CGRectMake(0,0,0,0)] autorelease];
             mTextField.delegate = self;
             /* placeholder so there is something to delete! (from SDL code) */
             mTextField.text = @" ";   
   
             /* set UITextInputTrait properties, mostly to defaults */
             mTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
             mTextField.autocorrectionType = UITextAutocorrectionTypeNo;
             mTextField.enablesReturnKeyAutomatically = NO;
             mTextField.keyboardAppearance = UIKeyboardAppearanceDefault;
             mTextField.keyboardType = UIKeyboardTypeDefault;
             mTextField.returnKeyType = UIReturnKeyDefault;
             mTextField.secureTextEntry = NO;   
             mTextField.hidden = YES;

	     [self addSubview: mTextField];

          }
          [mTextField becomeFirstResponder];
       }
       else
       {
          [mTextField resignFirstResponder];
       }
   }
}


- (void) drawView:(id)sender
{
   mStage->OnRedraw();
}

- (void) onPoll:(id)sender
{
   mStage->OnPoll();
}


- (void) layoutSubviews
{
   mStage->OnResizeLayer((CAEAGLLayer*)self.layer);
}

- (NSInteger) animationFrameInterval
{
   return animationFrameInterval;
}

- (void) setAnimationFrameInterval:(NSInteger)frameInterval
{
   // Frame interval defines how many display frames must pass between each time the
   // display link fires. The display link will only fire 30 times a second when the
   // frame internal is two on a display that refreshes 60 times a second. The default
   // frame interval setting of one will fire 60 times a second when the display refreshes
   // at 60 times a second. A frame interval setting of less than one results in undefined
   // behavior.
   if (frameInterval >= 1)
   {
      animationFrameInterval = frameInterval;
      
      if (animating)
      {
         [self stopAnimation];
         [self startAnimation];
      }
   }
}

- (void) startAnimation
{
   if (!animating)
   {
      /*
      if (displayLinkSupported)
      {
         // CADisplayLink is API new to iPhone SDK 3.1. Compiling against earlier versions
         // will result in a warning, but can be dismissed
         // if the system version runtime check for CADisplayLink exists in -initWithCoder:.
         // The runtime check ensures this code will
         // not be called in system versions earlier than 3.1.

         displayLink = [NSClassFromString(@"CADisplayLink") displayLinkWithTarget:self selector:@selector(drawView:)];
         [displayLink setFrameInterval:animationFrameInterval];
         [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
      }
      else
      */

         //animationTimer = [NSTimer
             //scheduledTimerWithTimeInterval:(NSTimeInterval)((1.0 / 60.0) * animationFrameInterval)
             //scheduledTimerWithTimeInterval:(NSTimeInterval)(0.0001)
             //target:self selector:@selector(onPoll:)
             //userInfo:nil
             //repeats:TRUE];
      
      animating = TRUE;
   }
}

- (void)stopAnimation
{
   if (animating)
   {
      if (displayLinkSupported)
      {
         [displayLink invalidate];
         displayLink = nil;
      }
      else
      {
         //[animationTimer invalidate];
         animationTimer = nil;
      }
      
      animating = FALSE;
   }
}

- (void) dealloc
{
    if (mStage) mStage->DecRef();
    if (mTextField)
       [mTextField release];
   
    [super dealloc];
}

@end


double sgWakeUp = 0.0;
bool sgTerminated = false;

// --- NMEAppDelegate ----------------------------------------------------------

class UIViewFrame : public nme::Frame
{
public:
   virtual void SetTitle()  { }
   virtual void SetIcon() { }
   virtual Stage *GetStage()  { return sgMainView->mStage; }

};

@implementation NMEAppDelegate

@synthesize window;
@synthesize controller;

namespace nme { void MainLoop(); }

- (void) applicationDidFinishLaunching:(UIApplication *)application
{
   UIWindow *win = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
   window = win;
   [window makeKeyAndVisible];
   UIStageViewController  *c = [[UIStageViewController alloc] init];
   controller = c;
   [win addSubview:c.view];
   //[c release];
   //[win release];
   nme_app_set_active(true);
   application.idleTimerDisabled = YES;
   sOnFrame( new UIViewFrame() );

   [self performSelectorOnMainThread:@selector(mainLoop) withObject:nil waitUntilDone:NO];
}

- (void) mainLoop {
   while(!sgTerminated)
   {
       double delta = sgMainView->mStage->GetNextWake() - GetTimeStamp();
       if (delta<0) delta = 0;
       if (CFRunLoopRunInMode(kCFRunLoopDefaultMode,delta,TRUE) != kCFRunLoopRunHandledSource)
       {
          sgMainView->mStage->OnPoll();
       }
   }
}





- (void) applicationWillResignActive:(UIApplication *)application {nme_app_set_active(false);} 
- (void) applicationDidBecomeActive:(UIApplication *)application {nme_app_set_active(true); }
- (void)applicationWillTerminate:(UIApplication *)application { nme_app_set_active(false); }


- (void) dealloc
{
	[window release];
	[controller release];
	[super dealloc];
}

@end



// --- Extenal Interface -------------------------------------------------------

void EnableKeyboard(bool inEnable)
{
   [ sgMainView enableKeyboard:inEnable];
}


/*
 These aren't part of the offical SDK
extern "C"
{
   extern int *_NSGetArgc(void);
   extern char ***_NSGetArgv(void);
};
*/


namespace nme
{
Stage *IPhoneGetStage() { return sgMainView->mStage; }

void TerminateMainLoop() { sgTerminated=true; }
void SetNextWakeUp(double inWakeUp) { sgWakeUp = inWakeUp; }


void CreateMainFrame(FrameCreationCallback inCallback,
   int inWidth,int inHeight,unsigned int inFlags, const char *inTitle, const char *inIcon )
{
   sOnFrame = inCallback;
   int argc = 0;// *_NSGetArgc();
   char **argv = 0;// *_NSGetArgv();

   NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
   UIApplicationMain(argc, argv, nil, @"NMEAppDelegate");
   [pool release];
}

bool GetAcceleration(double &outX, double &outY, double &outZ)
{
#ifdef IPHONESIM
   return false;
#else
   if (!sgMainView)
      return false;
   outX = sgMainView->mAccX;
   outY = sgMainView->mAccY;
   outZ = sgMainView->mAccZ;
   return true;
#endif
}


FILE *OpenRead(const char *inName)
{
    NSString *str = [[NSString alloc] initWithUTF8String:inName];
    NSString *path = [[NSBundle mainBundle] pathForResource:str ofType:nil];
    [str release];
    FILE * result = fopen([path cStringUsingEncoding:1],"rb");
    return result;
}

}

extern "C"
{

void nme_app_set_active(bool inActive)
{
   if (inActive)
      [ sgMainView startAnimation ];
   else
      [ sgMainView stopAnimation ];
}


}
