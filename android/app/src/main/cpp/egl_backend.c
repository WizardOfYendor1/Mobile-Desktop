// Android EGL/GLES implementation of lh_hw_backend.
//
// The core renders into an FBO this file owns; present() then draws that FBO's
// colour texture to the window surface with the vertical flip and rotation the
// host no longer bakes in, and swaps.
//
// THREADING. Everything that touches EGL or GL runs on the emulation thread,
// because that is the thread the context is current on and the thread the core
// calls us from. The one exception is egl_backend_set_window, which the
// platform thread calls when Flutter hands over a new Surface; it only stashes
// the window under a lock, and the EGLSurface is rebuilt at the next present.

#include "egl_backend.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define LOG_TAG "moonfin_egl"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

// GLES3 tokens used without linking libGLESv3: the entry points we need beyond
// GLES2 are resolved through eglGetProcAddress, so the library only has to
// link against GLESv2 and still run on a GLES3 context.
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
// From EGL_KHR_create_context. Declaring it here rather than pulling in
// eglext.h keeps this file to the core EGL headers.
#ifndef EGL_OPENGL_ES3_BIT_KHR
#define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif
#ifndef GL_DEPTH_STENCIL_ATTACHMENT
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#endif

typedef void(GL_APIENTRY *PFN_glBindVertexArray)(GLuint);
typedef void(GL_APIENTRY *PFN_glGenVertexArrays)(GLsizei, GLuint *);
typedef void(GL_APIENTRY *PFN_glDeleteVertexArrays)(GLsizei, const GLuint *);

typedef struct {
  EGLDisplay display;
  EGLConfig config;
  EGLContext context;
  EGLSurface surface;
  // Kept so the context can stay current while no window is available. EGL 1.5
  // makes surfaceless contexts core, but the Fire Cube reports EGL 1.4, so a
  // 1x1 pbuffer is the portable fallback and is cheap enough to always have.
  EGLSurface pbuffer;

  // The window present() draws into, and the one the platform most recently
  // handed over. They differ only between a Surface swap and the next present.
  ANativeWindow *window;
  ANativeWindow *pending_window;
  int window_dirty;
  pthread_mutex_t window_lock;

  // The core's render target. Allocated once at the core's declared maximum
  // and never resized: GLSM-based cores cache this handle a single time, so a
  // reallocation would hand them a name that no longer exists.
  GLuint fbo;
  GLuint color_tex;
  GLuint depth_rb;
  int fbo_width;
  int fbo_height;

  // The present pass.
  GLuint program;
  GLuint vbo;
  GLuint vao;
  GLint attr_pos;
  GLint attr_uv;
  GLint uniform_tex;
  PFN_glBindVertexArray bind_vao;
  PFN_glGenVertexArrays gen_vaos;
  PFN_glDeleteVertexArrays delete_vaos;

  int bottom_left_origin;
  int gles_major;
  int created;
  int logged_first_present;
  // Last geometry actually presented, so a CHANGE can be logged rather than
  // only the first frame. This is what tells us whether the window surface
  // tracks the core's render size or stays pinned at the base geometry - the
  // difference between a high internal resolution being displayed and being
  // downsampled away before it ever reaches the screen.
  int last_core_w, last_core_h, last_win_w, last_win_h;
} egl_state;

static egl_state g_egl;

// ---------------------------------------------------------------------------
// Shaders. Written to #version 100 so one program serves GLES2 and GLES3.

static const char *k_vertex_src =
    "attribute vec2 aPos;\n"
    "attribute vec2 aUV;\n"
    "varying vec2 vUV;\n"
    "void main() {\n"
    "  vUV = aUV;\n"
    "  gl_Position = vec4(aPos, 0.0, 1.0);\n"
    "}\n";

static const char *k_fragment_src =
    "precision mediump float;\n"
    "varying vec2 vUV;\n"
    "uniform sampler2D uTex;\n"
    "void main() {\n"
    "  gl_FragColor = vec4(texture2D(uTex, vUV).rgb, 1.0);\n"
    "}\n";

static GLuint compile_shader(GLenum type, const char *src) {
  GLuint s = glCreateShader(type);
  if (!s) return 0;
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[512];
    GLsizei len = 0;
    glGetShaderInfoLog(s, (GLsizei)sizeof(log), &len, log);
    LOGE("shader compile failed: %.*s", (int)len, log);
    glDeleteShader(s);
    return 0;
  }
  return s;
}

static int build_present_program(egl_state *s) {
  GLuint vs = compile_shader(GL_VERTEX_SHADER, k_vertex_src);
  GLuint fs = compile_shader(GL_FRAGMENT_SHADER, k_fragment_src);
  if (!vs || !fs) {
    if (vs) glDeleteShader(vs);
    if (fs) glDeleteShader(fs);
    return -1;
  }
  s->program = glCreateProgram();
  glAttachShader(s->program, vs);
  glAttachShader(s->program, fs);
  glLinkProgram(s->program);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(s->program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[512];
    GLsizei len = 0;
    glGetProgramInfoLog(s->program, (GLsizei)sizeof(log), &len, log);
    LOGE("present program link failed: %.*s", (int)len, log);
    glDeleteProgram(s->program);
    s->program = 0;
    return -1;
  }
  s->attr_pos = glGetAttribLocation(s->program, "aPos");
  s->attr_uv = glGetAttribLocation(s->program, "aUV");
  s->uniform_tex = glGetUniformLocation(s->program, "uTex");
  glGenBuffers(1, &s->vbo);

  // GLES3 requires a bound vertex array object for an attribute draw. If the
  // core leaves its own bound, our attribute setup would scribble on the
  // core's state instead of ours - so we always bind our own before drawing.
  s->gen_vaos = (PFN_glGenVertexArrays)eglGetProcAddress("glGenVertexArrays");
  s->bind_vao = (PFN_glBindVertexArray)eglGetProcAddress("glBindVertexArray");
  s->delete_vaos =
      (PFN_glDeleteVertexArrays)eglGetProcAddress("glDeleteVertexArrays");
  if (s->gen_vaos && s->bind_vao) s->gen_vaos(1, &s->vao);
  return 0;
}

// ---------------------------------------------------------------------------
// EGL setup

static EGLConfig choose_config(EGLDisplay dpy, int gles_major, int *out_ok) {
  const EGLint attrs[] = {EGL_SURFACE_TYPE,
                          EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE,
                          gles_major >= 3 ? EGL_OPENGL_ES3_BIT_KHR
                                          : EGL_OPENGL_ES2_BIT,
                          EGL_RED_SIZE,
                          8,
                          EGL_GREEN_SIZE,
                          8,
                          EGL_BLUE_SIZE,
                          8,
                          EGL_ALPHA_SIZE,
                          8,
                          EGL_NONE};
  EGLConfig config;
  EGLint count = 0;
  *out_ok = eglChooseConfig(dpy, attrs, &config, 1, &count) && count > 0;
  return config;
}

// A real creation attempt, which is the only honest way to answer this. No
// Android release mandates GLES 3.0 and devices above our minimum ship without
// it, so neither the OS version nor a parsed version string can be trusted.
static int egl_supports(void *user, const lh_hw_request *req) {
  (void)user;
  if (!req) return 0;
  int want_major;
  switch (req->api) {
    case LH_HW_API_GLES2:
      want_major = 2;
      break;
    case LH_HW_API_GLES:
      want_major = req->version_major >= 3 ? req->version_major : 3;
      break;
    default:
      return 0;  // Desktop GL and Vulkan are not available on this platform.
  }

  EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (dpy == EGL_NO_DISPLAY) return 0;
  // Re-initialising an already-initialised display is allowed and refcounted,
  // so probing while a session is live is safe.
  if (!eglInitialize(dpy, NULL, NULL)) return 0;

  int ok = 0;
  EGLConfig config = choose_config(dpy, want_major, &ok);
  if (!ok) {
    LOGI("no EGL config for GLES%d", want_major);
    return 0;
  }
  const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, want_major, EGL_NONE};
  EGLContext probe = eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs);
  if (probe == EGL_NO_CONTEXT) {
    LOGI("GLES%d context creation refused by the driver", want_major);
    return 0;
  }
  eglDestroyContext(dpy, probe);
  return 1;
}

static void destroy_fbo(egl_state *s) {
  if (s->fbo) glDeleteFramebuffers(1, &s->fbo);
  if (s->color_tex) glDeleteTextures(1, &s->color_tex);
  if (s->depth_rb) glDeleteRenderbuffers(1, &s->depth_rb);
  s->fbo = s->color_tex = s->depth_rb = 0;
}

static int create_fbo(egl_state *s, const lh_hw_request *req) {
  GLint max_tex = 0, max_rb = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_tex);
  glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &max_rb);
  int w = req->max_width;
  int h = req->max_height;
  if (max_tex > 0 && w > max_tex) w = max_tex;
  if (max_tex > 0 && h > max_tex) h = max_tex;
  if (req->depth && max_rb > 0) {
    if (w > max_rb) w = max_rb;
    if (h > max_rb) h = max_rb;
  }
  s->fbo_width = w;
  s->fbo_height = h;

  glGenTextures(1, &s->color_tex);
  glBindTexture(GL_TEXTURE_2D, s->color_tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  glGenFramebuffers(1, &s->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         s->color_tex, 0);

  // libretro's rule: depth alone is a plain depth buffer, depth+stencil is one
  // packed 24/8 buffer, and stencil without depth is invalid. The host already
  // dropped a lone stencil request, so only depth is checked here.
  if (req->depth) {
    glGenRenderbuffers(1, &s->depth_rb);
    glBindRenderbuffer(GL_RENDERBUFFER, s->depth_rb);
    if (req->stencil) {
      glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                GL_RENDERBUFFER, s->depth_rb);
    } else {
      glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, s->depth_rb);
    }
    glBindRenderbuffer(GL_RENDERBUFFER, 0);
  }

  GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    LOGE("render target incomplete (0x%x) at %dx%d", status, w, h);
    destroy_fbo(s);
    return -1;
  }
  LOGI("render target %dx%d, depth %d stencil %d", w, h, req->depth,
       req->stencil);
  return 0;
}

// Builds the EGLSurface for the current window, or falls back to the pbuffer
// when there is no window. Emulation thread only.
static int rebuild_surface(egl_state *s) {
  if (s->surface != EGL_NO_SURFACE) {
    // A Surface may only have one EGLSurface connected at a time, so ours has
    // to be fully released - not merely idle - before the next one is made.
    eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(s->display, s->surface);
    s->surface = EGL_NO_SURFACE;
  }
  if (s->window) {
    s->surface = eglCreateWindowSurface(s->display, s->config, s->window, NULL);
    if (s->surface == EGL_NO_SURFACE) {
      LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
    }
  }
  return s->surface != EGL_NO_SURFACE ? 0 : -1;
}

// Picks up a Surface the platform thread handed over. Emulation thread.
static void apply_pending_window(egl_state *s) {
  pthread_mutex_lock(&s->window_lock);
  if (!s->window_dirty) {
    pthread_mutex_unlock(&s->window_lock);
    return;
  }
  ANativeWindow *next = s->pending_window;
  s->window_dirty = 0;
  s->window = next;
  pthread_mutex_unlock(&s->window_lock);
  rebuild_surface(s);
}

static EGLSurface active_surface(egl_state *s) {
  return s->surface != EGL_NO_SURFACE ? s->surface : s->pbuffer;
}

static int egl_make_current(void *user) {
  egl_state *s = (egl_state *)user;
  if (s->context == EGL_NO_CONTEXT) return -1;
  EGLSurface surf = active_surface(s);
  if (!eglMakeCurrent(s->display, surf, surf, s->context)) {
    LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
    return -1;
  }
  return 0;
}

static void egl_release_current(void *user) {
  egl_state *s = (egl_state *)user;
  if (s->display != EGL_NO_DISPLAY) {
    eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}

static int egl_context_create(void *user, const lh_hw_request *req) {
  egl_state *s = (egl_state *)user;
  if (s->created) return 0;

  s->gles_major = req->api == LH_HW_API_GLES2
                      ? 2
                      : (req->version_major >= 3 ? req->version_major : 3);
  s->bottom_left_origin = req->bottom_left_origin;
  // Per CONTEXT, not per process: a core restart (a resolution change, say)
  // builds a new context with a new target size, and that is exactly when the
  // present geometry is worth logging again. Leaving this latched meant the
  // most interesting rebuild produced no diagnostic at all.
  s->logged_first_present = 0;

  s->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (s->display == EGL_NO_DISPLAY || !eglInitialize(s->display, NULL, NULL)) {
    LOGE("no EGL display");
    return -1;
  }
  int ok = 0;
  s->config = choose_config(s->display, s->gles_major, &ok);
  if (!ok) {
    LOGE("no EGL config for GLES%d", s->gles_major);
    return -1;
  }
  const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, s->gles_major,
                              EGL_NONE};
  s->context =
      eglCreateContext(s->display, s->config, EGL_NO_CONTEXT, ctx_attrs);
  if (s->context == EGL_NO_CONTEXT) {
    LOGE("eglCreateContext(GLES%d) failed: 0x%x", s->gles_major, eglGetError());
    return -1;
  }

  // The context outlives every Surface, so it always has somewhere to be
  // current even while Flutter is between Surfaces.
  const EGLint pb_attrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
  s->pbuffer = eglCreatePbufferSurface(s->display, s->config, pb_attrs);

  pthread_mutex_lock(&s->window_lock);
  if (s->window_dirty) {
    s->window = s->pending_window;
    s->window_dirty = 0;
  }
  pthread_mutex_unlock(&s->window_lock);
  rebuild_surface(s);

  if (egl_make_current(s) != 0) return -1;

  // PACING DECISION (design rev 2 section 5.3): the run loop paces the swap,
  // not the other way round.
  //
  // The software path deliberately blits on its own thread so the emulation
  // thread "stays paced by audio" (native_game_jni.c). On this path present()
  // runs on the emulation thread, so a vsync-blocking swap would make the
  // compositor a SECOND clock competing with lh_set_audio_paced - the run loop
  // would throttle on the audio ring and again on vsync, and the ring would
  // underrun. Interval 0 keeps audio as the only clock; the BufferQueue can
  // still push back when it is genuinely full, which is the backstop we want
  // rather than the mechanism we pace on.
  //
  // NOT YET CONFIRMED ON DEVICE. If this tears visibly on a TV panel, the
  // alternative is interval 1 plus dropping lh_set_audio_paced for hardware
  // cores - do not simply flip this without also moving the clock.
  eglSwapInterval(s->display, 0);

  if (create_fbo(s, req) != 0) return -1;
  if (build_present_program(s) != 0) return -1;

  const char *ver = (const char *)glGetString(GL_VERSION);
  const char *rend = (const char *)glGetString(GL_RENDERER);
  LOGI("context up: %s / %s", ver ? ver : "?", rend ? rend : "?");
  s->created = 1;
  return 0;
}

static void egl_context_destroy(void *user) {
  egl_state *s = (egl_state *)user;
  if (!s->created) return;
  if (s->display != EGL_NO_DISPLAY && s->context != EGL_NO_CONTEXT) {
    eglMakeCurrent(s->display, active_surface(s), active_surface(s),
                   s->context);
    destroy_fbo(s);
    if (s->program) glDeleteProgram(s->program);
    if (s->vbo) glDeleteBuffers(1, &s->vbo);
    if (s->vao && s->delete_vaos) s->delete_vaos(1, &s->vao);
    s->program = s->vbo = s->vao = 0;
    eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (s->surface != EGL_NO_SURFACE) eglDestroySurface(s->display, s->surface);
    if (s->pbuffer != EGL_NO_SURFACE) eglDestroySurface(s->display, s->pbuffer);
    eglDestroyContext(s->display, s->context);
    // Deliberately NOT eglTerminate(). The default display is shared with the
    // rest of the process - Flutter renders through it too (Skia GLES, since
    // Impeller is off on the TV flavors) - and eglTerminate marks EVERY
    // resource on that display for deletion, not just ours. eglInitialize is
    // not refcounted by the spec, so terminating here would pull the display
    // out from under Flutter's own renderer when a game ends. The Tegra driver
    // tolerated it across a whole test session, which is exactly how this kind
    // of bug ships and then fails on a different GPU. Releasing our own
    // context and surfaces is sufficient; the display connection legitimately
    // lives as long as the process.
  }
  s->surface = EGL_NO_SURFACE;
  s->pbuffer = EGL_NO_SURFACE;
  s->context = EGL_NO_CONTEXT;
  s->display = EGL_NO_DISPLAY;
  s->created = 0;
}

static lh_hw_target egl_current_target(void *user) {
  egl_state *s = (egl_state *)user;
  lh_hw_target t;
  t.kind = LH_HW_TARGET_GL_FBO;
  t.u.gl_fbo_name = s->fbo;
  return t;
}

// Resolves GL entry points for the core, including CORE GL functions and not
// just extensions.
//
// eglGetProcAddress alone is not enough. EGL 1.4 only requires it to resolve
// EXTENSION entry points; returning core functions from it is a driver
// courtesy, and the Fire TV Cube reports EGL 1.4. libretro is explicit that
// this callback must return "all relevant functions, including glClear"
// (libretro.h, retro_hw_render_callback::get_proc_address), so a core that
// resolves a core function here and receives NULL will call address zero -
// which presents as SIGSEGV with `#00 pc 0x0 <unknown>` and the core one frame
// above it. dlsym on the GLES libraries is the fallback RetroArch uses.
//
// Emulation thread only (the core resolves during context_reset), so the lazy
// handle initialisation below needs no lock.
static void *gles_dlsym(const char *sym) {
  static void *handles[3];
  static int opened;
  if (!opened) {
    opened = 1;
    // Newest first: a GLES3 context should prefer the GLES3 library's symbols.
    handles[0] = dlopen("libGLESv3.so", RTLD_LAZY | RTLD_LOCAL);
    handles[1] = dlopen("libGLESv2.so", RTLD_LAZY | RTLD_LOCAL);
    handles[2] = dlopen("libEGL.so", RTLD_LAZY | RTLD_LOCAL);
  }
  for (int i = 0; i < 3; i++) {
    if (!handles[i]) continue;
    void *p = dlsym(handles[i], sym);
    if (p) return p;
  }
  return NULL;
}

static void *egl_get_proc_address(void *user, const char *sym) {
  (void)user;
  if (!sym) return NULL;
  void *p = (void *)eglGetProcAddress(sym);
  if (!p) p = gles_dlsym(sym);
  if (!p) {
    // Worth knowing about: the core is about to receive NULL for something it
    // asked for, and cores do not always null-check the result.
    LOGE("could not resolve GL entry point '%s'", sym);
  }
  return p;
}

// Writes the four (u,v) pairs for the quad corners, applying the sub-rect the
// core actually used, the vertical flip, and the rotation.
//
// Corner order matches the position array below: bottom-left, bottom-right,
// top-left, top-right in clip space.
static void build_uvs(const egl_state *s, int width, int height, int rotation,
                      float out[8]) {
  float su = s->fbo_width > 0 ? (float)width / (float)s->fbo_width : 1.0f;
  float sv = s->fbo_height > 0 ? (float)height / (float)s->fbo_height : 1.0f;

  // Unit-square corners for an unrotated, unflipped image, in the same corner
  // order as the positions.
  float u[4] = {0.0f, 1.0f, 0.0f, 1.0f};
  float v[4] = {0.0f, 0.0f, 1.0f, 1.0f};

  // A core using libretro's top-left origin has its first row at the top,
  // which is the opposite of GL's window convention, so flip v.
  if (!s->bottom_left_origin) {
    for (int i = 0; i < 4; i++) v[i] = 1.0f - v[i];
  }

  // rotation is quarter turns counter-clockwise, per SET_ROTATION. Rotating
  // the sampling coordinates by -angle turns the displayed image by +angle.
  for (int i = 0; i < 4; i++) {
    float cu = u[i] - 0.5f;
    float cv = v[i] - 0.5f;
    float ru = cu, rv = cv;
    switch (rotation & 3) {
      case 1:
        ru = cv;
        rv = -cu;
        break;
      case 2:
        ru = -cu;
        rv = -cv;
        break;
      case 3:
        ru = -cv;
        rv = cu;
        break;
      default:
        break;
    }
    out[i * 2 + 0] = (ru + 0.5f) * su;
    out[i * 2 + 1] = (rv + 0.5f) * sv;
  }
}

static int egl_present(void *user, int width, int height, int rotation) {
  egl_state *s = (egl_state *)user;
  if (!s->created) return -1;

  // A Surface swap requested by the platform thread lands here, on the thread
  // that owns the context.
  apply_pending_window(s);

  if (s->surface == EGL_NO_SURFACE) {
    // Backgrounded, or between Surfaces. The frame is simply dropped; the core
    // keeps running and the next present will have somewhere to go.
    return 0;
  }
  if (eglMakeCurrent(s->display, s->surface, s->surface, s->context) !=
      EGL_TRUE) {
    LOGE("present: eglMakeCurrent failed 0x%x", eglGetError());
    return -1;
  }

  EGLint win_w = 0, win_h = 0;
  eglQuerySurface(s->display, s->surface, EGL_WIDTH, &win_w);
  eglQuerySurface(s->display, s->surface, EGL_HEIGHT, &win_h);
  if (win_w <= 0 || win_h <= 0) return 0;

  // Undo whatever the core left enabled. RetroArch had to fix scissor leakage
  // twice: a core returning with GL_SCISSOR_TEST on clips everything drawn
  // afterwards to its last scissor rectangle.
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_CULL_FACE);
  glDisable(GL_DITHER);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glDepthMask(GL_FALSE);
  glViewport(0, 0, win_w, win_h);
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);

  if (s->bind_vao && s->vao) s->bind_vao(s->vao);

  static const float pos[8] = {
      -1.0f, -1.0f,  // bottom-left
      1.0f,  -1.0f,  // bottom-right
      -1.0f, 1.0f,   // top-left
      1.0f,  1.0f,   // top-right
  };
  float uvs[8];
  build_uvs(s, width, height, rotation, uvs);
  float verts[16];
  for (int i = 0; i < 4; i++) {
    verts[i * 4 + 0] = pos[i * 2 + 0];
    verts[i * 4 + 1] = pos[i * 2 + 1];
    verts[i * 4 + 2] = uvs[i * 2 + 0];
    verts[i * 4 + 3] = uvs[i * 2 + 1];
  }

  glUseProgram(s->program);
  glBindBuffer(GL_ARRAY_BUFFER, s->vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
  glEnableVertexAttribArray((GLuint)s->attr_pos);
  glVertexAttribPointer((GLuint)s->attr_pos, 2, GL_FLOAT, GL_FALSE,
                        4 * sizeof(float), (const void *)0);
  glEnableVertexAttribArray((GLuint)s->attr_uv);
  glVertexAttribPointer((GLuint)s->attr_uv, 2, GL_FLOAT, GL_FALSE,
                        4 * sizeof(float), (const void *)(2 * sizeof(float)));
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, s->color_tex);
  glUniform1i(s->uniform_tex, 0);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

  glDisableVertexAttribArray((GLuint)s->attr_pos);
  glDisableVertexAttribArray((GLuint)s->attr_uv);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  if (s->bind_vao && s->vao) s->bind_vao(0);

  if (!eglSwapBuffers(s->display, s->surface)) {
    EGLint err = eglGetError();
    LOGE("eglSwapBuffers failed: 0x%x", err);
    if (err == EGL_BAD_SURFACE || err == EGL_BAD_NATIVE_WINDOW) {
      // The consumer went away underneath us. Drop the surface; the next
      // window handed over rebuilds it.
      eglMakeCurrent(s->display, s->pbuffer, s->pbuffer, s->context);
      eglDestroySurface(s->display, s->surface);
      s->surface = EGL_NO_SURFACE;
    }
    return -1;
  }

  // One line, once, so a device test can tell "presenting" from "running but
  // never reaching the screen" without a debugger. Everything needed to
  // diagnose an orientation or letterbox problem is in it.
  if (!s->logged_first_present || width != s->last_core_w ||
      height != s->last_core_h || (int)win_w != s->last_win_w ||
      (int)win_h != s->last_win_h) {
    const char *why = s->logged_first_present ? "geometry changed" : "first";
    s->logged_first_present = 1;
    s->last_core_w = width;
    s->last_core_h = height;
    s->last_win_w = (int)win_w;
    s->last_win_h = (int)win_h;
    // If core WxH exceeds window WxH, the present pass is downscaling and the
    // extra internal resolution is being discarded before it reaches the
    // screen - it buys antialiasing, not detail.
    LOGI("present (%s): core %dx%d into target %dx%d, window %dx%d%s, "
         "rotation %d, bottom_left_origin %d",
         why, width, height, s->fbo_width, s->fbo_height, (int)win_w,
         (int)win_h,
         (width > (int)win_w || height > (int)win_h) ? "  [DOWNSCALING]" : "",
         rotation, s->bottom_left_origin);
  }

  // The core draws into its own target, so leave that bound for the next
  // frame rather than making it re-query.
  glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
  return 0;
}

// ---------------------------------------------------------------------------

int egl_backend_install(lh_host *host) {
  memset(&g_egl, 0, sizeof(g_egl));
  pthread_mutex_init(&g_egl.window_lock, NULL);
  g_egl.display = EGL_NO_DISPLAY;
  g_egl.context = EGL_NO_CONTEXT;
  g_egl.surface = EGL_NO_SURFACE;
  g_egl.pbuffer = EGL_NO_SURFACE;

  lh_hw_backend backend;
  memset(&backend, 0, sizeof(backend));
  backend.struct_version = LH_HW_BACKEND_VERSION;
  backend.supports = egl_supports;
  backend.context_create = egl_context_create;
  backend.context_destroy = egl_context_destroy;
  backend.make_current = egl_make_current;
  backend.release_current = egl_release_current;
  backend.current_target = egl_current_target;
  backend.get_proc_address = egl_get_proc_address;
  backend.present = egl_present;
  return lh_set_hw_backend(host, &backend, &g_egl);
}

void egl_backend_set_window(ANativeWindow *window) {
  pthread_mutex_lock(&g_egl.window_lock);
  g_egl.pending_window = window;
  g_egl.window_dirty = 1;
  pthread_mutex_unlock(&g_egl.window_lock);
}

void egl_backend_shutdown(void) {
  pthread_mutex_lock(&g_egl.window_lock);
  g_egl.pending_window = NULL;
  g_egl.window_dirty = 1;
  pthread_mutex_unlock(&g_egl.window_lock);
}
