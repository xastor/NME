#include <Display.h>
#include <Utils.h>
#include <SDL.h>
#include <Surface.h>
#include <ExternalInterface.h>
#include <KeyCodes.h>
#include <map>

namespace nme
{

void SetGlobalPollMethod(Stage::PollMethod inMethod);

class SDLSurf : public Surface
{
public:
   SDLSurf(SDL_Surface *inSurf,uint32 inFlags,bool inDelete) : mSurf(inSurf)
   {
      mDelete = inDelete;
   }
   ~SDLSurf()
   {
      if (mDelete)
         SDL_FreeSurface(mSurf);
   }

   int Width() const  { return mSurf->w; }
   int Height() const  { return mSurf->h; }
   PixelFormat Format()  const
   {
      if (mSurf->flags & SDL_SRCALPHA)
          return pfARGB;
      return pfXRGB;
   }
   const uint8 *GetBase() const { return (const uint8 *)mSurf->pixels; }
   int GetStride() const { return mSurf->pitch; }

   void Clear(uint32 inColour,const Rect *inRect)
   {
      SDL_Rect r;
      SDL_Rect *rect_ptr = 0;
      if (inRect)
      {
         rect_ptr = &r;
         r.x = inRect->x;
         r.y = inRect->y;
         r.w = inRect->w;
         r.h = inRect->h;
      }

      SDL_FillRect(mSurf,rect_ptr,SDL_MapRGBA(mSurf->format,
            inColour>>16, inColour>>8, inColour, inColour>>24 )  );
   }

   RenderTarget BeginRender(const Rect &inRect)
   {
      if (SDL_MUSTLOCK(mSurf) )
         SDL_LockSurface(mSurf);
      return RenderTarget(Rect(Width(),Height()), Format(),
         (uint8 *)mSurf->pixels, mSurf->pitch);
   }
   void EndRender()
   {
      if (SDL_MUSTLOCK(mSurf) )
         SDL_UnlockSurface(mSurf);
   }

   void BlitTo(const RenderTarget &outTarget,
               const Rect &inSrcRect,int inPosX, int inPosY,
               BlendMode inBlend, const BitmapCache *inMask,
               uint32 inTint=0xffffff )
   {
   }


   SDL_Surface *mSurf;
   bool  mDelete;
};


SDL_Cursor *CreateCursor(const char *image[],int inHotX,int inHotY)
{
  int i, row, col;
  Uint8 data[4*32];
  Uint8 mask[4*32];

  i = -1;
  for ( row=0; row<32; ++row ) {
    for ( col=0; col<32; ++col ) {
      if ( col % 8 ) {
        data[i] <<= 1;
        mask[i] <<= 1;
      } else {
        ++i;
        data[i] = mask[i] = 0;
      }
      switch (image[row][col]) {
        case 'X':
          data[i] |= 0x01;
          mask[i] |= 0x01;
          break;
        case '.':
          mask[i] |= 0x01;
          break;
        case ' ':
          break;
      }
    }
  }
  return SDL_CreateCursor(data, mask, 32, 32, inHotX, inHotY);
}

SDL_Cursor *sDefaultCursor = 0;
SDL_Cursor *sTextCursor = 0;



class SDLStage : public Stage
{
public:
   SDLStage(SDL_Surface *inSurface,uint32 inFlags,bool inIsOpenGL)
   {
      mIsOpenGL = inIsOpenGL;
      mSDLSurface = inSurface;
      if (mIsOpenGL)
      {
         mOpenGLContext = HardwareContext::CreateOpenGL(0,0);
         mOpenGLContext->SetWindowSize(inSurface->w, inSurface->h);
         mPrimarySurface = new HardwareSurface(mOpenGLContext);
      }
      else
      {
         mOpenGLContext = 0;
         mPrimarySurface = new SDLSurf(inSurface,inFlags,inIsOpenGL);
      }
      mPrimarySurface->IncRef();
   }
   ~SDLStage()
   {
      if (!mIsOpenGL)
         SDL_FreeSurface(mSDLSurface);
      mPrimarySurface->DecRef();
   }

   void ProcessEvent(Event &inEvent)
   {
      HandleEvent(inEvent);
   }

   void Flip()
   {
      if (mIsOpenGL)
      {
         SDL_GL_SwapBuffers();
      }
      else
      {
         SDL_Flip( mSDLSurface );
      }
   }
   void GetMouse()
   {
   }

   void SetCursor(Cursor inCursor)
   {
      if (sDefaultCursor==0)
         sDefaultCursor = SDL_GetCursor();
   
      if (inCursor==curNone)
         SDL_ShowCursor(false);
      else
      {
         SDL_ShowCursor(true);
   
         if (inCursor==curPointer || inCursor==curHand)
            SDL_SetCursor(sDefaultCursor);
         else
         {
            if (sTextCursor==0)
               sTextCursor = CreateCursor(sTextCursorData,1,13);
            SDL_SetCursor(sTextCursor);
         }
      }
   }
   

   void SetPollMethod(PollMethod inMethod)
   {
      SetGlobalPollMethod(inMethod);
   }


   Surface *GetPrimarySurface()
   {
      return mPrimarySurface;
   }

   HardwareContext *mOpenGLContext;
   SDL_Surface *mSDLSurface;
   Surface     *mPrimarySurface;
   double       mFrameRate;
   bool         mIsOpenGL;
};


class SDLFrame : public Frame
{
public:
   SDLFrame(SDL_Surface *inSurface, uint32 inFlags, bool inIsOpenGL)
   {
      mFlags = inFlags;
      mStage = new SDLStage(inSurface,mFlags,inIsOpenGL);
      mStage->IncRef();
      // SetTimer(mHandle,timerFrame, 10,0);
   }
   ~SDLFrame()
   {
      mStage->DecRef();
   }

   void ProcessEvent(Event &inEvent)
   {
      mStage->ProcessEvent(inEvent);
   }
   // --- Frame Interface ----------------------------------------------------

   void SetTitle()
   {
   }
   void SetIcon()
   {
   }
   Stage *GetStage()
   {
      return mStage;
   }


   SDLStage *mStage;
   uint32 mFlags;
};


// --- When using the simple window class -----------------------------------------------

extern "C" void MacBoot( /*void (*)()*/ );


SDLFrame *sgSDLFrame = 0;

Frame *CreateMainFrame(int inWidth,int inHeight,unsigned int inFlags,
          const char *inTitle, const char *inIcon)
{
#ifdef HX_MACOS
   MacBoot();
#endif

   unsigned int sdl_flags = 0;
   bool fullscreen = (inFlags & wfFullScreen) != 0;
   bool opengl = (inFlags & wfHardware) != 0;
   bool resizable = (inFlags & wfResizable) != 0;

   Rect r(100,100,inWidth,inHeight);

   Uint32 init_flags = SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER;
   if (opengl)
      init_flags |= SDL_OPENGL;

   //  SDL_GL_DEPTH_SIZE = 0;

   init_flags |= SDL_INIT_JOYSTICK;

   if ( SDL_Init( init_flags ) == -1 )
   {
      // SDL_GetError()
      return 0;
   }

   SDL_EnableUNICODE(1);
   SDL_EnableKeyRepeat(500,30);

   sdl_flags = SDL_HWSURFACE;

   if ( resizable )
      sdl_flags |= SDL_RESIZABLE;

   if ( fullscreen )
      sdl_flags |= SDL_FULLSCREEN;


   int use_w = fullscreen ? 0 : inWidth;
   int use_h = fullscreen ? 0 : inHeight;

#ifdef IPHONE
   sdl_flags |= SDL_NOFRAME;
#else
   // SDL_WM_SetIcon( icn, NULL );
#endif

   SDL_Surface* screen = 0;
   bool is_opengl = false;
   if (opengl)
   {
      /* Initialize the display */
      SDL_GL_SetAttribute(SDL_GL_RED_SIZE,  8 );
      SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE,8 );
      SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8 );
      SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 32);
      SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

      if ( inFlags & wfVSync )
      {
         SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, 1);
      }

      sdl_flags |= SDL_OPENGL;
      if (!(screen = SDL_SetVideoMode( use_w, use_h, 32, sdl_flags | SDL_OPENGL)))
      {
         sdl_flags &= ~SDL_OPENGL;
         fprintf(stderr, "Couldn't set OpenGL mode: %s\n", SDL_GetError());
      }
      else
      {
        is_opengl = true;
        //Not great either way
        //glEnable( GL_LINE_SMOOTH );  
        //glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);  
      }
   }


   if (!screen)
   {
      sdl_flags |= SDL_DOUBLEBUF;
      screen = SDL_SetVideoMode( use_w, use_h, 32, sdl_flags );
      //printf("Flags %p\n",sdl_flags);
      if (!screen)
      {
         // SDL_GetError()
         return 0;
      }
   }

   HintColourOrder( opengl || screen->format->Rmask==0xff );

   #ifndef IPHONE
   SDL_WM_SetCaption( inTitle, 0 );
   #endif

   #ifdef NME_MIXER
   if ( Mix_OpenAudio( MIX_DEFAULT_FREQUENCY, MIX_DEFAULT_FORMAT, MIX_DEFAULT_CHANNELS,4096 )!= 0 )
      printf("unable to initialize the sound support\n");
   #endif

   sgSDLFrame =  new SDLFrame( screen, sdl_flags, is_opengl );
   return sgSDLFrame;
}

bool sgDead = false;

void TerminateMainLoop()
{
   #ifdef NME_MIXER
   Mix_CloseAudio();
   #endif
   sgDead = true;
}

static Stage::PollMethod sgPollMethod = Stage::pollAlways;
static SDL_TimerID  sgTimerID = 0;

Uint32 DoPoll(Uint32 interval, void *)
{
    // Ping off an event - any event will force the frame check.
    SDL_Event event;
    SDL_UserEvent userevent;
    /* In this example, our callback pushes an SDL_USEREVENT event
    into the queue, and causes ourself to be called again at the
    same interval: */
    userevent.type = SDL_USEREVENT;
    userevent.code = 0;
    userevent.data1 = NULL;
    userevent.data2 = NULL;
    event.type = SDL_USEREVENT;
    event.user = userevent;
    SDL_PushEvent(&event);
    return interval;
}


void SetGlobalPollMethod(Stage::PollMethod inMethod)
{
   if (inMethod!=sgPollMethod)
   {
      sgPollMethod = inMethod;
      if (sgPollMethod==Stage::pollTimer)
      {
         sgTimerID = SDL_AddTimer(1, DoPoll, 0);
      }
      else if (sgTimerID)
      {
         SDL_RemoveTimer(sgTimerID);
         sgTimerID = 0;
      }
   }
}

void AddModStates(int &ioFlags,int inState = -1)
{
   int state = inState==-1 ? SDL_GetModState() : inState;
   if (state & KMOD_SHIFT) ioFlags |= efShiftDown;
   if (state & KMOD_CTRL) ioFlags |= efCtrlDown;
   if (state & KMOD_ALT) ioFlags |= efAltDown;
   if (state & KMOD_META) ioFlags |= efCommandDown;

   int m = SDL_GetMouseState(0,0);
   if ( m & SDL_BUTTON(1) ) ioFlags |= efLeftDown;
   if ( m & SDL_BUTTON(2) ) ioFlags |= efMiddleDown;
   if ( m & SDL_BUTTON(3) ) ioFlags |= efRightDown;
}

#define SDL_TRANS(x) case SDLK_##x: return key##x;

int SDLKeyToFlash(int inKey,bool &outRight)
{
   outRight = (inKey==SDLK_RSHIFT || inKey==SDLK_RCTRL ||
               inKey==SDLK_RALT || inKey==SDLK_RMETA || inKey==SDLK_RSUPER);
   if (inKey>=keyA && inKey<=keyZ)
      return inKey;
   if (inKey>=SDLK_0 && inKey<=SDLK_9)
      return inKey - SDLK_0 + keyNUMBER_0;
   if (inKey>=SDLK_KP0 && inKey<=SDLK_KP9)
      return inKey - SDLK_KP0 + keyNUMPAD_0;

   if (inKey>=SDLK_F1 && inKey<=SDLK_F15)
      return inKey - SDLK_F1 + keyF1;


   switch(inKey)
   {
      case SDLK_RALT:
      case SDLK_LALT:
         return keyALTERNATE;
      case SDLK_RSHIFT:
      case SDLK_LSHIFT:
         return keySHIFT;
      case SDLK_RCTRL:
      case SDLK_LCTRL:
         return keyCONTROL;
      case SDLK_LMETA:
      case SDLK_RMETA:
         return keyCOMMAND;

      case SDLK_CAPSLOCK: return keyCAPS_LOCK;
      case SDLK_PAGEDOWN: return keyPAGE_DOWN;
      case SDLK_PAGEUP: return keyPAGE_UP;
      case SDLK_EQUALS: return keyEQUAL;
      case SDLK_RETURN:
      case SDLK_KP_ENTER:
         return keyENTER;

      SDL_TRANS(BACKQUOTE)
      SDL_TRANS(BACKSLASH)
      SDL_TRANS(BACKSPACE)
      SDL_TRANS(COMMA)
      SDL_TRANS(DELETE)
      SDL_TRANS(DOWN)
      SDL_TRANS(END)
      SDL_TRANS(ESCAPE)
      SDL_TRANS(HOME)
      SDL_TRANS(INSERT)
      SDL_TRANS(LEFT)
      SDL_TRANS(LEFTBRACKET)
      SDL_TRANS(MINUS)
      SDL_TRANS(PERIOD)
      SDL_TRANS(QUOTE)
      SDL_TRANS(RIGHT)
      SDL_TRANS(RIGHTBRACKET)
      SDL_TRANS(SEMICOLON)
      SDL_TRANS(SLASH)
      SDL_TRANS(SPACE)
      SDL_TRANS(TAB)
      SDL_TRANS(UP)
   }

   return inKey;
}

std::map<int,wchar_t> sLastUnicode;

void ProcessEvent(SDL_Event &inEvent)
{
  switch(inEvent.type)
   {
      case SDL_QUIT:
      {
         Event close(etQuit);
         sgSDLFrame->ProcessEvent(close);
         break;
      }
      case SDL_MOUSEMOTION:
      {
         Event mouse(etMouseMove,inEvent.motion.x,inEvent.motion.y);
         AddModStates(mouse.flags);
         sgSDLFrame->ProcessEvent(mouse);
         break;
      }
      case SDL_MOUSEBUTTONDOWN:
      {
         Event mouse(etMouseDown,inEvent.button.x,inEvent.button.y);
         AddModStates(mouse.flags);
         sgSDLFrame->ProcessEvent(mouse);
         break;
      }
      case SDL_MOUSEBUTTONUP:
      {
         Event mouse(etMouseUp,inEvent.button.x,inEvent.button.y);
         AddModStates(mouse.flags);
         sgSDLFrame->ProcessEvent(mouse);
         break;
      }

      case SDL_KEYDOWN:
      case SDL_KEYUP:
      {
         Event key(inEvent.type==SDL_KEYDOWN ? etKeyDown : etKeyUp );
         bool right;
         key.value = SDLKeyToFlash(inEvent.key.keysym.sym,right);
         if (inEvent.type==SDL_KEYDOWN)
         {
            key.code = inEvent.key.keysym.unicode;
            sLastUnicode[inEvent.key.keysym.scancode] = key.code;
         }
         else
            // SDL does not provide unicode on key up, so remember it,
            //  keyed by scancode
            key.code = sLastUnicode[inEvent.key.keysym.scancode];

         AddModStates(key.flags,inEvent.key.keysym.mod);
         if (right)
            key.flags |= efLocationRight;
         sgSDLFrame->ProcessEvent(key);
         break;
      }

      case SDL_VIDEORESIZE:
      {
         break;
      }
   }
}


#ifdef NME_MIXER
int id = soundGetNextDoneChannel();
if (id>=0)
{
}
#endif



void MainLoop()
{
   SDL_Event event;
   while(!sgDead)
   {
      while ( SDL_PollEvent(&event) )
      {
         ProcessEvent(event);
         if (sgDead) break;
      }
     
      if (sgPollMethod!=Stage::pollNever)
      {
         Event poll(etPoll);
         sgSDLFrame->ProcessEvent(poll);
      }
      
      if (!sgDead && sgPollMethod!=Stage::pollAlways)
      {
         SDL_WaitEvent(&event);
         ProcessEvent(event);
      }
   }

   Event kill(etDestroyHandler);
   sgSDLFrame->ProcessEvent(kill);
   SDL_Quit();
}


Frame *CreateTopLevelWindow(int inWidth,int inHeight,unsigned int inFlags, wchar_t *inTitle, wchar_t *inIcon )
{

}



} // end namespace nme


         #if 0
         if (event.type == SDL_JOYAXISMOTION)
         {
       alloc_field( evt, val_id( "type" ), alloc_int( et_jaxis ) );
       alloc_field( evt, val_id( "axis" ), alloc_int( event.jaxis.axis ) );
       alloc_field( evt, val_id( "value" ), alloc_int( event.jaxis.value ) );
       alloc_field( evt, val_id( "which" ), alloc_int( event.jaxis.which ) );
       return evt;
         }
         if (event.type == SDL_JOYBUTTONDOWN || event.type == SDL_JOYBUTTONUP)
         {
       alloc_field( evt, val_id( "type" ), alloc_int( et_jbutton ) );
       alloc_field( evt, val_id( "button" ), alloc_int( event.jbutton.button ) );
       alloc_field( evt, val_id( "state" ), alloc_int( event.jbutton.state ) );
       alloc_field( evt, val_id( "which" ), alloc_int( event.jbutton.which ) );
       return evt;
         }
         if (event.type == SDL_JOYHATMOTION)
         {
       alloc_field( evt, val_id( "type" ), alloc_int( et_jhat ) );
       alloc_field( evt, val_id( "button" ), alloc_int( event.jhat.hat ) );
       alloc_field( evt, val_id( "value" ), alloc_int( event.jhat.value ) );
       alloc_field( evt, val_id( "which" ), alloc_int( event.jhat.which ) );
       return evt;
         }
         if (event.type == SDL_JOYBALLMOTION)
         {
       alloc_field( evt, val_id( "type" ), alloc_int( et_jball ) );
       alloc_field( evt, val_id( "ball" ), alloc_int( event.jball.ball ) );
       alloc_field( evt, val_id( "xrel" ), alloc_int( event.jball.xrel ) );
       alloc_field( evt, val_id( "yrel" ), alloc_int( event.jball.yrel ) );
       alloc_field( evt, val_id( "which" ), alloc_int( event.jball.which ) );
       return evt;
         }

         if (event.type==SDL_VIDEORESIZE)
         {
       alloc_field( evt, val_id( "type" ), alloc_int( et_resize ) );
       alloc_field( evt, val_id( "width" ), alloc_int( event.resize.w ) );
       alloc_field( evt, val_id( "height" ), alloc_int( event.resize.h ) );
       return evt;
         }
         #endif


#if 0
/*
 */


value nme_set_clip_rect(value inSurface, value inRect)
{
   SDL_Rect rect;
   if (!val_is_null(inRect))
   {
      rect.x = (int)val_number( val_field(inRect, val_id("x")) );
      rect.y = (int)val_number( val_field(inRect, val_id("y")) );
      rect.w = (int)val_number( val_field(inRect, val_id("width")) );
      rect.h = (int)val_number( val_field(inRect, val_id("height")) );

   }
   else
      memset(&rect,0,sizeof(rect));

   if (val_is_kind(inSurface,k_surf))
   {
      SDL_Surface *surface = SURFACE(inSurface);

      if (IsOpenGLScreen(surface))
      {
         if (val_is_null(inRect))
         {
            sDoScissor = false;
            glDisable(GL_SCISSOR_TEST);
         }
         else
         {
            sDoScissor = true;
            glEnable(GL_SCISSOR_TEST);
            sScissorRect = rect;
            glScissor(sScissorRect.x,sScissorRect.y,
                      sScissorRect.w,sScissorRect.h);
         }
      }
      else
      {
         if (val_is_null(inRect))
         {
            SDL_SetClipRect(surface,0);
            SDL_GetClipRect(surface,&rect);
         }
         else
         {
            SDL_SetClipRect(surface,&rect);
         }
      }
   }

   return AllocRect(rect);
}

value nme_get_clip_rect(value inSurface)
{
   SDL_Rect rect;
   memset(&rect,0,sizeof(rect));

   if (val_is_kind(inSurface,k_surf))
   {
      SDL_Surface *surface = SURFACE(inSurface);

      if (IsOpenGLScreen(surface))
      {
         if (sDoScissor)
            rect = sScissorRect;
         else
         {
            rect.w = sOpenGLScreen->w;
            rect.h = sOpenGLScreen->h;
         }
      }
      else
      {
         SDL_GetClipRect(surface,&rect);
      }
   }

   return AllocRect(rect);
}

value nme_get_mouse_position()
{
   int x,y;

   #ifdef SDL13
   SDL_GetMouseState(0,&x,&y);
   #else
   SDL_GetMouseState(&x,&y);
   #endif

   value pos = alloc_empty_object();
   alloc_field( pos, val_id( "x" ), alloc_int( x ) );
   alloc_field( pos, val_id( "y" ), alloc_int( y ) );
   return pos;
}


#define NME_FULLSCREEN 0x0001
#define NME_OPENGL_FLAG  0x0002
#define NME_RESIZABLE  0x0004
#define NME_HWSURF     0x0008
#define NME_VSYNC      0x0010

#ifdef __APPLE__

extern "C" void MacBoot( /*void (*)()*/ );

#endif

value nme_resize_surface(value inW, value inH)
{
   val_check( inW, int );
   val_check( inH, int );
   int w = val_int(inW);
   int h = val_int(inH);
   SDL_Surface *screen = gCurrentScreen;

   #ifndef __APPLE__
   if (is_opengl)
   {
      // Little hack to help windows
      screen->w = w;
      screen->h = h;
   }
   else
   #endif
   {
      nme_resize_id ++;
      // Calling this recreates the gl context and we loose all our textures and
      // display lists. So Work around it.
      gCurrentScreen = screen = SDL_SetVideoMode(w, h, 32, sdl_flags );
   }

   return alloc_abstract( k_surf, screen );
}





#endif