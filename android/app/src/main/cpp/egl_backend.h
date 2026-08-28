// Android's implementation of the host's platform-agnostic graphics backend
// (lh_hw_backend). Everything EGL and GL stays behind this boundary, exactly
// as ANativeWindow stays out of libretro_host.h.

#ifndef MOONFIN_EGL_BACKEND_H
#define MOONFIN_EGL_BACKEND_H

#include <android/native_window.h>

#include "libretro_host.h"

// Registers the EGL backend with [host]. Call once, before lh_load, since a
// core asks for its context during retro_load_game. Returns 0 on success.
int egl_backend_install(lh_host *host);

// Hands over the window the presented frame goes to, or NULL when the surface
// is going away. Safe to call from the platform thread: the window is only
// stashed here, and the EGLSurface is actually swapped on the emulation thread
// at the next present. Doing it inline would touch EGL from the wrong thread.
void egl_backend_set_window(ANativeWindow *window);

// Drops any state the backend still holds. Safe to call when nothing was ever
// created.
void egl_backend_shutdown(void);

#endif  // MOONFIN_EGL_BACKEND_H
