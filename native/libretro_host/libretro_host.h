// Portable libretro host. One instance runs a single core (libretro's C
// callbacks carry no user data, so only one session exists per process). The
// host owns the run loop, pixel conversion, an audio ring, save states, core
// options, and SRAM. The platform supplies a texture sink, an input source, and
// an audio device through the callbacks below, so Android and every desktop
// share this code.

#ifndef LIBRETRO_HOST_H
#define LIBRETRO_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lh_host lh_host;

// Result codes for lh_load and lh_probe_options. The VALUES are fixed: platform
// runners map them to channel errors and the self-test asserts them, so name
// them, never renumber them.
//
// Scoped to the load path. Other entry points also return -1 as a plain
// failure without meaning LH_ERR_SESSION_BUSY.
typedef enum {
  LH_OK = 0,
  LH_ERR_SESSION_BUSY = -1,      // a core is already loaded in this process
  LH_ERR_CORE_OPEN = -2,         // the module could not be opened
  LH_ERR_CORE_SYMBOLS = -3,      // required libretro symbols are missing
  LH_ERR_ROM_READ = -4,          // the content file could not be read
  LH_ERR_CONTENT_REJECTED = -5,  // retro_load_game returned false
  LH_ERR_AUDIO_RING = -6,        // the audio ring could not be sized/allocated
  // The same value under its other meaning. The overload predates the names
  // and the value is part of the contract, so both spellings stay.
  LH_ERR_SHUTDOWN_DURING_LOAD = -6,
  LH_ERR_ALLOC = -7,             // a host allocation failed
  LH_ERR_BAD_GAME_ID = -8,       // game_id would escape save_dir
} lh_result;

// Ports the input latch tracks. Matches the largest per-platform mask array
// (Android, macOS/iOS); the desktop runners only ever touch port 0.
#define LH_MAX_PORTS 4

// The 32-bit layout the host writes converted frames in. Pick whichever the
// platform texture expects: Flutter desktop pixel buffers want RGBA, a macOS
// CVPixelBuffer wants BGRA.
typedef enum {
  LH_FORMAT_RGBA8888 = 0,
  LH_FORMAT_BGRA8888 = 1,
} lh_output_format;

typedef struct {
  // Post-rotation display geometry: when the core requested a 90 or 270 degree
  // rotation, width/height are already swapped and aspect already inverted, so
  // these match the frames lh_get_frame hands back.
  int width;
  int height;
  double aspect;
  double fps;
  double sample_rate;
  // 0, 1, 2, 3 = 0, 90, 180, 270 degrees counter-clockwise, per
  // RETRO_ENVIRONMENT_SET_ROTATION. Informational: the host already bakes the
  // rotation into the converted frame, so platforms need not act on it.
  int rotation;
} lh_av_info;

typedef struct {
  void *user;
  // A new converted frame is ready. The platform pulls it with lh_get_frame.
  // Called from the run-loop thread.
  void (*frame_ready)(void *user);
  // Number of connected controllers, for the player-count event.
  int (*controller_count)(void *user);
  // The core changed its output geometry or aspect ratio.
  void (*geometry_changed)(void *user, int width, int height, double aspect);
  // A message the core wants shown, such as a missing-system-files warning.
  // Arrives on the run-loop thread, or on the caller's thread during lh_load.
  // Optional, may be NULL.
  void (*message)(void *user, const char *text);
  // The core asked to quit, which cores do when a boot or a reset fails. The
  // loop has stopped and the core is already unloaded, so the platform should
  // end the session and tell the user. Called once, from the run-loop thread as
  // it exits, so post the teardown elsewhere rather than calling lh_stop or
  // lh_destroy from here. Optional, may be NULL.
  void (*core_shutdown)(void *user);
  // The emulation thread is terminating because of an unrecoverable error.
  // Distinct from core_shutdown, which is the core asking to quit cleanly.
  // Optional, may be NULL. Called from the run-loop thread.
  void (*fatal_error)(void *user, const char *message);
} lh_callbacks;

// ---------------------------------------------------------------------------
// Hardware rendering: the platform-supplied graphics backend.
//
// The second interface a platform supplies, alongside lh_callbacks. A backend
// stands up a graphics context and a render target that the CORE draws into,
// which inverts the software path: there, the core hands back a CPU
// framebuffer the host converts and the platform blits. Here no CPU frame ever
// exists - the core renders on the GPU and video_refresh only says "done".
//
// DELIBERATELY CONTEXT-AGNOSTIC. No EGL, GL, Vulkan, Metal or CoreVideo type
// appears anywhere below, exactly as ANativeWindow already stays in the
// Android layer rather than in this header. Every platform's frame sink is a
// Flutter external texture - Android hands over a Surface/BufferQueue while
// the other four hand over a pixel buffer - so an interface shaped around any
// one platform's context API would not fit the other four.
//
// Registering a backend does NOT by itself enable hardware rendering. The
// core has to ask for it (RETRO_ENVIRONMENT_SET_HW_RENDER) and the backend has
// to agree (supports). Until both happen, lh_hw_active stays 0 and the entire
// software path runs exactly as it does with no backend registered at all.

// Bumped whenever lh_hw_backend gains or changes a field. A backend stamps the
// version it was compiled against; lh_set_hw_backend refuses anything it does
// not recognise, rather than reading past the end of an older struct.
//
// This is the seam a Vulkan backend arrives through. Vulkan's model is not a
// variation on GL's - the core receives a device from the frontend and hands
// back an image, so there is no framebuffer name anywhere in it. Version 2
// would append the negotiation and image-handoff entry points; a version-1
// GL backend keeps working untouched, because nothing it already declares
// moves or changes meaning.
#define LH_HW_BACKEND_VERSION 1

// Graphics APIs a core can ask for and a backend can provide. These mirror
// retro_hw_context_type without dragging libretro.h into this header, so the
// platform layer never has to include it.
typedef enum {
  LH_HW_API_NONE = 0,
  // RETRO_HW_CONTEXT_OPENGLES2. Not legacy trivia: PPSSPP's Android build asks
  // for exactly this, so a GLES3-only backend cannot serve it.
  LH_HW_API_GLES2 = 1,
  // RETRO_HW_CONTEXT_OPENGLES3 and RETRO_HW_CONTEXT_OPENGLES_VERSION, with the
  // requested level in version_major/version_minor (3.0, 3.1, 3.2).
  LH_HW_API_GLES = 2,
  // RETRO_HW_CONTEXT_OPENGL: desktop compatibility-profile GL.
  LH_HW_API_GL = 3,
  // RETRO_HW_CONTEXT_OPENGL_CORE, with the level in version_major/minor.
  LH_HW_API_GL_CORE = 4,
  // Reserved. No backend implements this and the host refuses
  // RETRO_HW_CONTEXT_VULKAN; the value exists so the enum does not have to
  // change shape later. See LH_HW_BACKEND_VERSION.
  LH_HW_API_VULKAN = 5,
} lh_hw_api;

// What a core asked for, normalised for the backend.
typedef struct {
  lh_hw_api api;
  // Only meaningful for LH_HW_API_GL_CORE and for the OPENGLES_VERSION form of
  // LH_HW_API_GLES; zero otherwise.
  int version_major;
  int version_minor;
  // Depth/stencil attachments the core requested. libretro's rule, which the
  // backend must follow: depth alone means a plain depth buffer, depth and
  // stencil together mean one packed 24/8 buffer, and stencil WITHOUT depth is
  // invalid and must be ignored rather than honoured.
  int depth;
  int stencil;
  // Non-zero when the core draws with GL's bottom-left origin. The host's
  // texture path is top-left, so the backend flips in present.
  int bottom_left_origin;
  // The core asked for a debug context. Advisory: a backend may ignore it.
  int debug_context;
  // The largest frame the core can ever produce, from retro_get_system_av_info.
  //
  // SIZE THE RENDER TARGET TO THIS, ONCE, AND NEVER RESIZE IT. A later
  // geometry change moves the viewport and the sub-rect present samples; it
  // must not reallocate the target. Cores built on libretro's GLSM helper -
  // which includes both cores this work targets - cache the target handle a
  // single time and rebind that cached value every frame, so a reallocated
  // target hands them a name that no longer exists and they render into
  // nothing. See current_target.
  int max_width;
  int max_height;
} lh_hw_request;

// The render target the core draws into, as an opaque tagged handle rather
// than a graphics-API type. A GL backend reports a framebuffer object name; a
// future Vulkan backend reports an image through the same struct without
// changing this signature or the struct's size.
#define LH_HW_TARGET_NONE 0
#define LH_HW_TARGET_GL_FBO 1
typedef struct {
  // One of the LH_HW_TARGET_* values above.
  uint32_t kind;
  union {
    // LH_HW_TARGET_GL_FBO. A GLuint widened to 64 bits so this header needs no
    // GL types; the backend narrows it back on its own side.
    uint64_t gl_fbo_name;
    void *opaque;
  } u;
} lh_hw_target;

// The backend itself. Every entry point is REQUIRED - lh_set_hw_backend
// rejects a partially filled table rather than null-checking on the hot path.
//
// THREADING: supports may be called from any thread. Everything else runs on
// the emulation thread with the context current, because that is where the
// core runs and a graphics context belongs to one thread at a time. The
// platform's own lifecycle events arrive on the platform thread, so they must
// hand work across rather than touching the context directly.
typedef struct {
  // LH_HW_BACKEND_VERSION at compile time.
  uint32_t struct_version;

  // Can this platform actually provide [req]? Returns non-zero if so.
  //
  // This has to be a real attempt - creating a throwaway context at the
  // requested version and seeing whether it succeeds. It must not be answered
  // from an OS version, a GPU name, or a parsed version string: no Android
  // release mandates GLES 3.0, and devices above the app's minimum ship
  // without it. A wrong "yes" here turns today's clean, actionable "this game
  // cannot be played with the native core" into a black screen.
  int (*supports)(void *user, const lh_hw_request *req);

  // Create the context and the render target sized per [req]. Returns 0 on
  // success. Called once per load, AFTER the core's retro_load_game returns
  // and before the host issues the core's context_reset.
  int (*context_create)(void *user, const lh_hw_request *req);

  // Tear the context down. The host calls this while the context is still
  // current and before the core is unloaded.
  void (*context_destroy)(void *user);

  // Bind/unbind the context on the calling (emulation) thread. Returns 0 on
  // success. The host makes the context current before the core's
  // context_reset and before every frame.
  int (*make_current)(void *user);
  void (*release_current)(void *user);

  // The target the core should render into this frame.
  //
  // MUST BE STABLE FOR THE WHOLE SESSION. libretro permits a frontend to
  // rotate this per frame, and RetroArch does, but we must not: see the
  // max_width note on lh_hw_request for why a changing handle breaks GLSM
  // cores.
  lh_hw_target (*current_target)(void *user);

  // Resolve a graphics entry point by name, for the core's own loader.
  void *(*get_proc_address)(void *user, const char *sym);

  // Present the frame the core just drew, applying the vertical flip implied
  // by bottom_left_origin and [rotation]. Returns 0 on success.
  //
  // [width]/[height] are the core's CURRENT output size, which is the sub-rect
  // of the (larger, fixed) render target that actually holds this frame.
  // [rotation] is 0, 1, 2, 3 for 0, 90, 180, 270 degrees counter-clockwise,
  // per RETRO_ENVIRONMENT_SET_ROTATION.
  //
  // On the software path the host bakes rotation into the converted frame. On
  // this path there is no conversion step to bake it into, so the backend owns
  // it. A backend that ignores [rotation] silently ships sideways games.
  int (*present)(void *user, int width, int height, int rotation);
} lh_hw_backend;

// Bounds for the option snapshot below. The host only speaks the legacy
// SET_VARIABLES form ("Label; a|b|c" - GET_CORE_OPTIONS_VERSION is answered
// with 0), where ids, labels, and values are all short, so these caps are
// generous rather than tight. Anything longer is truncated, never overrun.
#define LH_OPTION_ID_MAX 128
#define LH_OPTION_LABEL_MAX 256
#define LH_OPTION_VALUE_MAX 128
#define LH_OPTION_CHOICE_MAX 64

// One controller configuration the core advertised for an emulated input
// port. This is a caller-owned snapshot, just like lh_option: labels supplied
// by RETRO_ENVIRONMENT_SET_CONTROLLER_INFO belong to the core and may be
// replaced immediately after the environment callback returns.
#define LH_CONTROLLER_TYPE_LABEL_MAX 256
typedef struct {
  unsigned id;
  char label[LH_CONTROLLER_TYPE_LABEL_MAX];
} lh_controller_type;

// One RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS entry, copied: like
// lh_controller_type, the core owns the string and may replace it as soon as
// the environment callback returns.
#define LH_INPUT_DESCRIPTOR_LABEL_MAX 256
typedef struct {
  unsigned port;
  unsigned device;
  unsigned index;
  unsigned id;
  char description[LH_INPUT_DESCRIPTOR_LABEL_MAX];
} lh_input_descriptor;

// One core option and its choices, as a caller-owned snapshot.
//
// These used to be borrowed pointers into the host's own allocations, which
// was not safe to hand out: restart_core frees every definition on the
// emulation thread and lh_set_option frees the old value on whichever thread
// changed it, so a caller reading its lh_option afterwards read freed memory.
// lh_get_option now copies everything under the host's option lock, so a
// snapshot stays valid for as long as the caller keeps the struct, whatever
// the other threads do to the host in the meantime.
typedef struct {
  char id[LH_OPTION_ID_MAX];
  char label[LH_OPTION_LABEL_MAX];
  char current[LH_OPTION_VALUE_MAX];
  char choices[LH_OPTION_CHOICE_MAX][LH_OPTION_VALUE_MAX];
  // Choices actually copied, so it never exceeds LH_OPTION_CHOICE_MAX even if
  // the core published more.
  int choice_count;
} lh_option;

// Creates a host that writes frames in [fmt] and reports back through [cb].
lh_host *lh_create(lh_output_format fmt, lh_callbacks cb);

// Reports the RetroPad button mask (RETRO_DEVICE_ID_JOYPAD_* bits) currently
// held on [port]. Call this every time the platform's raw input state
// changes - on a key/button edge, a controller value-changed callback, a
// method-channel message, whatever the platform's transport is - not once
// per frame. The host does not sample this instantaneously: every mask
// reported between two core polls is OR'd into a pending latch, so a press
// whose down and up both land inside one ~16.7ms poll window is still
// observed by the core for exactly one frame, and reads of different button
// ids within the same frame stay coherent (RetroArch does the same thing).
// A bit held continuously across many frames stays set in every one of them.
// Thread-safe and safe to call before a core is loaded or after lh_stop; the
// write just has nothing to be read by yet. [port] outside
// [0, LH_MAX_PORTS) is ignored.
void lh_set_input(lh_host *host, int port, uint16_t mask);

// Whole-pad state in one call: the digital mask plus the analog axes and
// trigger pressures. One call rather than several keeps the digital and analog
// stores adjacent, so a poll rarely lands between them, and halves the
// per-event platform-boundary crossings.
//
// Axes are -32768..32767; triggers are 0..0x7fff.
void lh_set_pad_state(lh_host *host, int port, uint16_t mask,
                      int16_t lx, int16_t ly, int16_t rx, int16_t ry,
                      uint16_t l2, uint16_t r2);

// Loads [core_path] and [rom_path]. [system_dir] and [save_dir] back the core's
// directory requests. [game_id] names the SRAM file. [opt_keys]/[opt_vals] seed
// core options (may be NULL when [opt_count] is 0). Fills [out_info] and returns
// 0 on success, non-zero on failure.
int lh_load(lh_host *host, const char *core_path, const char *rom_path,
            const char *system_dir, const char *save_dir, const char *game_id,
            const char *const *opt_keys, const char *const *opt_vals,
            int opt_count, lh_av_info *out_info);

// Runs, pauses, or tears down the emulation. lh_stop flushes SRAM and unloads
// the core, so the host can then be destroyed or loaded again.
// lh_start returns 0 when the emulation thread is running (including when it
// already was), non-zero when it could not be created.
int lh_start(lh_host *host);
void lh_pause(lh_host *host);
void lh_resume(lh_host *host);
// Fully recreates the core and reloads its current content. Unlike lh_reset,
// this applies options that a core only reads during initialization.
int lh_restart(lh_host *host);
// Schedules the same restart on the emulation thread without waiting for it.
// Returns non-zero when no running core can accept the request.
int lh_restart_async(lh_host *host);
// Increments once for every restart the run loop applies, whether scheduled by
// lh_restart or lh_restart_async and whether it succeeds or fails. Lets a
// caller poll for a scheduled restart to actually land before reading state
// that only makes sense post-restart.
unsigned lh_restart_generation(lh_host *host);
void lh_reset(lh_host *host);
void lh_set_fast_forward(lh_host *host, int factor);
void lh_stop(lh_host *host);
void lh_destroy(lh_host *host);

// Registers the platform's graphics backend, or clears it with a NULL
// [backend]. Call before lh_load: a core asks for a hardware context during
// retro_load_game, and a backend registered after that is too late to matter.
//
// [backend] is COPIED, so the caller may keep it on the stack; [user] is
// retained and must outlive the host. Returns 0 on success, -1 for a NULL
// host, an unrecognised struct_version, or a table with any entry point left
// NULL - all of which are programming errors, not runtime conditions.
//
// Registering a backend on its own changes NOTHING about how frames flow. It
// only makes the host able to say yes when a core asks for a context.
int lh_set_hw_backend(lh_host *host, const lh_hw_backend *backend, void *user);

// The size the core will render at on the hardware path, so the platform can
// size its presentation surface to match instead of to the core's much smaller
// base geometry. Returns 1 and fills [width]/[height] when a hardware context
// was negotiated, 0 otherwise (and leaves the out-params alone).
//
// Valid as soon as lh_load returns - the core asks for its context during
// retro_load_game, so the size is known before the run loop ever starts. That
// matters: it lets the platform get the surface right BEFORE first use, rather
// than resizing it mid-session and forcing a surface swap.
//
// This is the render target's size, i.e. the largest frame the core can
// produce. Its aspect ratio is the core's own, so a platform scaling it to fit
// a display must scale BOTH axes by the same factor or it will distort the
// picture.
int lh_hw_render_size(lh_host *host, int *width, int *height);

// Whether the CURRENT load is rendering through the backend. 0 means the
// software path, including whenever no core is loaded.
//
// The platform must branch on this rather than infer the path, and must not
// call lh_get_frame while it is non-zero - on the hardware path there is no
// converted frame to get, because the pixels never touched the CPU.
int lh_hw_active(lh_host *host);

// Tells the host the graphics context died outside its control - a lost
// device, a driver reset, a surface torn away by the OS.
//
// The host re-issues the core's context_reset before the next frame WITHOUT
// calling context_destroy first, which is what libretro requires: after an
// uncontrolled loss the core must treat its old resources as already gone and
// must not try to free them. Safe to call from any thread, with or without a
// core loaded or a backend registered.
void lh_notify_hw_context_lost(lh_host *host);

// Copies the latest frame under the host's lock. Returns 1 and fills the out
// params when a frame exists, 0 otherwise. The pointer stays valid until the
// next lh_get_frame call.
//
// Software path only. See lh_hw_active.
int lh_get_frame(lh_host *host, const void **data, int *width, int *height,
                 int *stride);

// Pulls up to [frame_count] interleaved stereo S16 frames into [dst], returning
// the count written. Silence fills any shortfall. The platform audio device
// calls this, and the ring fill also paces the run loop.
int lh_read_audio(lh_host *host, int16_t *dst, int frame_count);

// Switches the run loop from wall-clock timing to audio-buffer pacing. The
// platform sets this once its audio device is pulling, so audio is the clock.
void lh_set_audio_paced(lh_host *host, int paced);

// Save states. lh_serialize_size is an upper bound for the buffer. lh_serialize
// and lh_unserialize return 0 on success. They run between frames on the run
// loop, so they never race retro_run.
size_t lh_serialize_size(lh_host *host);
int lh_serialize(lh_host *host, void *dst, size_t size);
int lh_unserialize(lh_host *host, const void *src, size_t size);

// Core options. lh_option_count and lh_get_option read the definitions the core
// published, and lh_set_option changes a value. lh_get_option fills [out] with
// a self-contained copy taken under the host's option lock, so the caller owns
// the strings and nothing invalidates them. Returns 0 on success, -1 for a NULL
// argument or an index outside the current definitions - and note the count can
// shrink between the two calls, because a restart on the emulation thread
// rebuilds the whole definition list. Treat a -1 as "stop enumerating", not as
// a hole to skip past.
int lh_option_count(lh_host *host);
int lh_get_option(lh_host *host, int index, lh_option *out);
void lh_set_option(lh_host *host, const char *id, const char *value);

// Reads a core's option definitions without loading content, so a core whose
// game will not start is still configurable. Definitions are host-owned copies
// readable through lh_option_count/lh_get_option afterwards; a core may publish
// more from retro_load_game, so this can be a subset. Returns 0 on success.
//
// Refused while any session is loaded: libretro's callbacks carry no user data,
// so a second module would be handed the running core's environment callback.
int lh_probe_options(lh_host *host, const char *core_path,
                     const char *system_dir);

// Controller configurations reported through
// RETRO_ENVIRONMENT_SET_CONTROLLER_INFO. The host logs every port and type the
// core reports (including unsupported extras), and retains snapshots for the
// Moonfin input ports it can route.
// lh_get_controller_type copies one entry into caller-owned storage; it returns
// -1 for a NULL host/out or an index outside the latest snapshot. A core may
// publish a replacement snapshot at any time, so treat that result as the end
// of enumeration rather than a hole.
int lh_controller_type_count(lh_host *host, int port);
int lh_get_controller_type(lh_host *host, int port, int index,
                           lh_controller_type *out);

// Core-supplied (port, device, index, id) -> label entries. Returns -1 for a
// NULL host/out or an index past the latest snapshot; since a core may publish
// a replacement snapshot at any time (notably after
// retro_set_controller_port_device), treat -1 as end of enumeration, not a hole.
int lh_input_descriptor_count(lh_host *host);
int lh_get_input_descriptor(lh_host *host, int index,
                            lh_input_descriptor *out);

// Applies a controller device on the emulation thread. RETRO_DEVICE_JOYPAD is
// Auto/the libretro default and is always accepted, even when it is not in a
// core's advertised list. An explicit unadvertised device safely falls back to
// that default and returns 1; an exact or Auto application returns 0. Returns
// -1 when the port is outside Moonfin's input range, no loaded core exports
// retro_set_controller_port_device, or the host can no longer run a job.
int lh_set_controller_type(lh_host *host, int port, unsigned device);

// Bitmask of ports the current game describes ANALOG controls for, from
// RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS. Bit N = port N.
//
// This is per-GAME and authoritative, unlike "did the core query analog":
// FBNeo queries analog for every game including purely 4-way ones, so that
// signal cannot distinguish BurgerTime (no analog descriptors) from Capcom
// Bowling (Trackball X/Y).
unsigned lh_analog_descriptor_ports(lh_host *host);

// Test-only: drives one input-latch step directly, without a running core or
// run loop, and reads the value that step produced for [port]. This is the
// exact same latch step input_poll_cb runs once per real libretro poll (see
// lh_set_input) - these exist so its exactly-once-per-edge semantics can be
// verified deterministically in native/libretro_host/test, instead of racing
// a live run loop's wall-clock pacing. Not part of the platform-facing
// contract; no shipping caller should need these.
void lh_test_poll_input(lh_host *host);
// A core-driven poll inside retro_run: latches without advancing expiry.
void lh_test_core_poll_input(lh_host *host);
uint16_t lh_test_read_input(lh_host *host, int port);
// Test-only: reads the post-latch analog snapshot ([index] 0=left, 1=right
// stick; [axis] 0=X, 1=Y) and trigger snapshot ([which] 0=L2, 1=R2) for
// [port], exactly like lh_test_read_input reads input_frame. See that
// comment for why these hooks exist.
int16_t lh_test_read_analog(lh_host *host, int port, int index, int axis);
uint16_t lh_test_read_trigger(lh_host *host, int port, int which);

// Distinct environment commands this host has answered with the default
// false. Test-only: the diagnostic those commands emit goes to stderr or
// logcat, which the harness cannot read, so the dedupe is observed here.
int lh_test_unhandled_env_count(lh_host *host);

// How many times a core read input from a thread other than the one that
// latched it. Non-zero means the input frame is being published across
// threads without synchronisation.
int lh_test_input_thread_mismatch(lh_host *host);

// Reads a port the way a core does, INCLUDING acknowledging the edge bits it
// returns. lh_test_read_input peeks without acknowledging; use this one to
// assert the delivered-once contract.
uint16_t lh_test_observe_input(lh_host *host, int port);

// Reads one button the way a core querying ids individually does: returns that
// bit and acknowledges only it, leaving other buttons' edges undelivered.
int lh_test_observe_input_id(lh_host *host, int port, unsigned id);

#ifdef __cplusplus
}
#endif

#endif  // LIBRETRO_HOST_H
