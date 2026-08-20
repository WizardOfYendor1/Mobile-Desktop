// A minimal libretro core for exercising the host without a real emulator. Each
// frame it advances a counter, paints a frame whose colours encode the counter
// and the current input, emits audio, and keeps the counter as its save state.
//
// stub_pattern switches the painted frame to a coordinate-encoded test
// pattern instead, for pinning down convert_frame's rotation and pixel-format
// handling: stub_rotation drives RETRO_ENVIRONMENT_SET_ROTATION and
// stub_format drives RETRO_ENVIRONMENT_SET_PIXEL_FORMAT.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../libretro.h"

#define STUB_WIDTH 64
#define STUB_HEIGHT 48

static retro_environment_t env_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t input_poll_cb;
static retro_input_state_t input_state_cb;

// Sized for the widest format (XRGB8888 at 4 bytes/pixel); narrower formats
// use a shorter pitch and leave the tail unused.
static uint8_t framebuffer[STUB_WIDTH * STUB_HEIGHT * 4];
static int32_t frame_counter;
static int32_t speed_fast;
static int32_t pattern_mode;
static enum retro_pixel_format pixel_fmt;
static uint8_t sram[64];
// stub_huge_frame/stub_bad_pitch drive the host's video_refresh_cb bounds
// checks directly (LH_MAX_FRAME_DIMENSION and the pitch >= width*bpp check in
// convert_frame): each makes retro_run hand the host a frame the real
// hardware could never produce, so a test can confirm the host rejects it
// cleanly (no frame delivered, no crash) instead of converting it.
static int32_t huge_frame_mode;
static int32_t bad_pitch_mode;
// When on, retro_run queries input_state_cb directly for RETRO_DEVICE_ANALOG
// (both stick indices, the analog-button plane's L2/R2 and a derived id) and
// for the untouched MOUSE/LIGHTGUN/POINTER domains, then reports every result
// through SET_MESSAGE. This exercises input_state_cb's actual dispatch (index
// and id mapping, derivation from the digital mask), which the frame-snapshot
// test hooks (lh_test_read_analog/lh_test_read_trigger) intentionally bypass.
static int32_t analog_check_mode;

// Holds onto a GET_VARIABLE pointer across frames the way a real core does,
// so the host's promise that the pointer stays readable for the life of the
// load can be checked. The first retro_run stashes the pointer for
// "stub_speed" plus a private copy of the string; once the host reports the
// variables dirty (i.e. the platform thread ran lh_set_option and replaced
// that value), a later retro_run reads the *stashed* pointer again. Before
// the retired-value arena, vars_set had already freed it and this read is a
// heap-use-after-free under ASAN.
static const char *stashed_value;
static char stashed_copy[32];
// 0 = not re-read yet, 1 = re-read and the bytes still matched, 2 = re-read
// and the bytes had changed. Exposed through the save state so the harness
// can assert on it.
static int32_t stash_recheck;
static int32_t saw_variable_update;

#define STUB_CLASSIC_PAD RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 1)

// The labels are deliberately overwritten immediately after the environment
// call. A frontend that only borrows SET_CONTROLLER_INFO strings will then
// expose the mutated values instead of the capability snapshot it received.
static char controller_label_classic[32];
static char controller_label_modern[32];
static char controller_label_lightgun[32];
static char controller_label_mouse[32];
static char controller_label_pointer[32];
static char controller_label_keyboard[32];
static char controller_label_extra[32];
static struct retro_controller_description controller_types_0[] = {
    {controller_label_classic, STUB_CLASSIC_PAD},
    {controller_label_modern, RETRO_DEVICE_JOYPAD},
    {controller_label_lightgun, RETRO_DEVICE_LIGHTGUN},
};
static struct retro_controller_description controller_types_1[] = {
    {controller_label_mouse, RETRO_DEVICE_MOUSE},
};
static struct retro_controller_description controller_types_2[] = {
    {controller_label_pointer, RETRO_DEVICE_POINTER},
};
static struct retro_controller_description controller_types_3[] = {
    {controller_label_keyboard, RETRO_DEVICE_KEYBOARD},
};
static struct retro_controller_description controller_types_4[] = {
    {controller_label_extra, RETRO_DEVICE_ANALOG},
};
static struct retro_controller_info controller_info[] = {
    {controller_types_0, 3},
    {controller_types_1, 1},
    {controller_types_2, 1},
    {controller_types_3, 1},
    {controller_types_4, 1},
    {NULL, 0},
};
static unsigned controller_devices[4];

// Same borrowed-pointer discipline as controller_info above: the labels are
// static buffers overwritten immediately after the SET_INPUT_DESCRIPTORS
// call, so a frontend that only borrowed the strings instead of copying them
// would expose the mutated text instead of the original descriptions. Spans
// two ports and several distinct ids, including id 0 (RETRO_DEVICE_ID_JOYPAD_B)
// and id 8 (RETRO_DEVICE_ID_JOYPAD_A) to catch an off-by-default-zero bug in
// the id field specifically.
static char id_label_port0_b[32];
static char id_label_port0_a[32];
static char id_label_port0_start[32];
static char id_label_port1_b[32];
static struct retro_input_descriptor input_descriptors[] = {
    {0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B, id_label_port0_b},
    {0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A, id_label_port0_a},
    {0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_START, id_label_port0_start},
    {1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B, id_label_port1_b},
    {0, 0, 0, 0, NULL},
};

static void stash_reset(void) {
  stashed_value = NULL;
  stashed_copy[0] = '\0';
  stash_recheck = 0;
  saw_variable_update = 0;
}

// Runs once per frame, before the frame is painted.
static void stash_step(void) {
  if (!stashed_value) {
    struct retro_variable speed = {"stub_speed", NULL};
    env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &speed);
    if (!speed.value) return;
    stashed_value = speed.value;
    size_t n = strlen(speed.value);
    if (n > sizeof(stashed_copy) - 1) n = sizeof(stashed_copy) - 1;
    memcpy(stashed_copy, speed.value, n);
    stashed_copy[n] = '\0';
    // Swallow the dirty flag the initial SET_VARIABLES raised, so only an
    // option change made after the stash arms the re-read below.
    bool ignored = false;
    env_cb(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &ignored);
    return;
  }
  bool updated = false;
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated);
  if (updated) saw_variable_update = 1;
  if (saw_variable_update && stash_recheck == 0) {
    stash_recheck = strcmp(stashed_value, stashed_copy) == 0 ? 1 : 2;
  }
}

void retro_set_environment(retro_environment_t cb) {
  env_cb = cb;
  static const struct retro_variable vars[] = {
      {"stub_speed", "Speed; normal|fast"},
      {"stub_pattern", "Pattern; off|on"},
      {"stub_rotation", "Rotation; 0|1|2|3"},
      {"stub_format", "Pixel format; xrgb8888|rgb565|0rgb1555"},
      {"stub_huge_frame", "Huge frame; off|on"},
      {"stub_bad_pitch", "Bad pitch; off|on"},
      {"stub_vfs_dir_check", "VFS dir check; off|on"},
      {"stub_analog_check", "Analog check; off|on"},
      {NULL, NULL},
  };
  env_cb(RETRO_ENVIRONMENT_SET_VARIABLES, (void *)vars);
  strcpy(controller_label_classic, "Stub Classic");
  strcpy(controller_label_modern, "Stub Modern");
  strcpy(controller_label_lightgun, "Stub Lightgun");
  strcpy(controller_label_mouse, "Stub Mouse");
  strcpy(controller_label_pointer, "Stub Pointer");
  strcpy(controller_label_keyboard, "Stub Keyboard");
  strcpy(controller_label_extra, "Stub Extra");
  env_cb(RETRO_ENVIRONMENT_SET_CONTROLLER_INFO, controller_info);
  strcpy(controller_label_classic, "changed");
  strcpy(controller_label_modern, "changed");
  strcpy(controller_label_lightgun, "changed");
  strcpy(controller_label_mouse, "changed");
  strcpy(controller_label_pointer, "changed");
  strcpy(controller_label_keyboard, "changed");
  strcpy(controller_label_extra, "changed");

  strcpy(id_label_port0_b, "Fire");
  strcpy(id_label_port0_a, "Jump");
  strcpy(id_label_port0_start, "Coin");
  strcpy(id_label_port1_b, "P2 Fire");
  env_cb(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS, input_descriptors);
  strcpy(id_label_port0_b, "changed");
  strcpy(id_label_port0_a, "changed");
  strcpy(id_label_port0_start, "changed");
  strcpy(id_label_port1_b, "changed");
}
// Set from the ROM contents, to mimic a core whose boot fails a few frames in:
// it asks the frontend to quit and would fault if it were run again.
static int shutdown_frame;
static int did_shutdown;
static retro_log_printf_t log_cb;

// Mirrors the operations FBNeo's minizip reader performs after it switches
// libretro-common over to a frontend-provided VFS: open the archive, retain
// its path, find the end-of-central-directory record from EOF, then return to
// the local header. Keeping this in the stub makes the host regression suite
// deterministic without depending on a downloaded third-party core.
static bool probe_vfs_zip(const char *path) {
  struct retro_vfs_interface_info info = {3, NULL};
  if (!env_cb(RETRO_ENVIRONMENT_GET_VFS_INTERFACE, &info) || !info.iface) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: interface unavailable\n");
    return false;
  }

  struct retro_vfs_file_handle *file =
      info.iface->open(path, RETRO_VFS_FILE_ACCESS_READ,
                       RETRO_VFS_FILE_ACCESS_HINT_NONE);
  if (!file) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: open failed\n");
    return false;
  }

  bool ok = true;
  const char *reported_path = info.iface->get_path(file);
  if (!reported_path || strcmp(reported_path, path) != 0) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: get_path failed\n");
    ok = false;
  }

  int64_t size = info.iface->size(file);
  // FBNeo's bundled minizip adapter uses stdio fseek semantics: zero means
  // success, then tell supplies the resulting position. libretro-common's
  // built-in VFS implementation follows that convention too.
  if (size < 22 || info.iface->seek(file, 0, RETRO_VFS_SEEK_POSITION_END) != 0 ||
      info.iface->tell(file) != size) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: size/end seek failed\n");
    ok = false;
  }

  uint8_t signature[4] = {0};
  if (size < 22 ||
      info.iface->seek(file, -22, RETRO_VFS_SEEK_POSITION_END) != 0 ||
      info.iface->tell(file) != size - 22 ||
      info.iface->read(file, signature, sizeof(signature)) !=
          (int64_t)sizeof(signature) ||
      memcmp(signature, "PK\x05\x06", sizeof(signature)) != 0) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: central directory seek/read failed\n");
    ok = false;
  }

  memset(signature, 0, sizeof(signature));
  if (info.iface->seek(file, 0, RETRO_VFS_SEEK_POSITION_START) != 0 ||
      info.iface->tell(file) != 0 ||
      info.iface->read(file, signature, sizeof(signature)) !=
          (int64_t)sizeof(signature) ||
      memcmp(signature, "PK\x03\x04", sizeof(signature)) != 0) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: local header seek/read failed\n");
    ok = false;
  }

  if (info.iface->close(file) != 0) {
    log_cb(RETRO_LOG_ERROR, "stub VFS ZIP probe: close failed\n");
    ok = false;
  }
  return ok;
}

// Walks the system directory through the VFS and reports whether "probe_subdir"
// came back as a directory. Covers opendir/readdir/closedir traversal - notably
// the Win32 pending-first-entry path - since SET_MESSAGE is the stub's only
// channel back to the harness.
static void probe_vfs_dir(void) {
  struct retro_vfs_interface_info info = {3, NULL};
  if (!env_cb(RETRO_ENVIRONMENT_GET_VFS_INTERFACE, &info) || !info.iface) {
    struct retro_message msg = {"stub vfs dir probe: interface unavailable", 180};
    env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
    return;
  }
  const char *sysdir = NULL;
  env_cb(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, &sysdir);
  if (!sysdir) {
    struct retro_message msg = {"stub vfs dir probe: no system directory", 180};
    env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
    return;
  }
  struct retro_vfs_dir_handle *d = info.iface->opendir(sysdir, true);
  bool found_entry = false;
  bool found_dir = false;
  if (d) {
    while (info.iface->readdir(d)) {
      const char *name = info.iface->dirent_get_name(d);
      if (name && strcmp(name, "probe_subdir") == 0) {
        found_entry = true;
        found_dir = info.iface->dirent_is_dir(d);
        break;
      }
    }
    info.iface->closedir(d);
  }
  struct retro_message msg = {
      (found_entry && found_dir) ? "stub vfs dir probe_subdir is a directory"
                                  : "stub vfs dir probe_subdir NOT a directory",
      180};
  env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
}

// Drives input_state_cb directly for RETRO_DEVICE_ANALOG plus the domains the
// analog design deliberately leaves untouched, and reports every result
// through SET_MESSAGE so the harness can parse them back out. Port 0 for the
// analog/mouse reads, port 1 for lightgun, matching what a real core's query
// pattern looks like (see the design doc's measured tuples).
static void probe_analog(void) {
  int16_t lx = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_LEFT,
                              RETRO_DEVICE_ID_ANALOG_X);
  int16_t ly = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_LEFT,
                              RETRO_DEVICE_ID_ANALOG_Y);
  int16_t rx = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_RIGHT,
                              RETRO_DEVICE_ID_ANALOG_X);
  int16_t ry = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_RIGHT,
                              RETRO_DEVICE_ID_ANALOG_Y);
  int16_t l2 = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_BUTTON,
                              RETRO_DEVICE_ID_JOYPAD_L2);
  int16_t r2 = input_state_cb(0, RETRO_DEVICE_ANALOG,
                              RETRO_DEVICE_INDEX_ANALOG_BUTTON,
                              RETRO_DEVICE_ID_JOYPAD_R2);
  // Derived-from-digital ids: whatever bit is (or isn't) set in the JOYPAD
  // mask for this port right now.
  int16_t derived_b = input_state_cb(0, RETRO_DEVICE_ANALOG,
                                     RETRO_DEVICE_INDEX_ANALOG_BUTTON,
                                     RETRO_DEVICE_ID_JOYPAD_B);
  int16_t derived_start = input_state_cb(0, RETRO_DEVICE_ANALOG,
                                         RETRO_DEVICE_INDEX_ANALOG_BUTTON,
                                         RETRO_DEVICE_ID_JOYPAD_START);
  int16_t mouse_x =
      input_state_cb(0, RETRO_DEVICE_MOUSE, 0, RETRO_DEVICE_ID_MOUSE_X);
  int16_t gun_x = input_state_cb(1, RETRO_DEVICE_LIGHTGUN, 0,
                                 RETRO_DEVICE_ID_LIGHTGUN_SCREEN_X);
  int16_t pointer_x =
      input_state_cb(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_X);

  char text[256];
  snprintf(text, sizeof(text),
          "stub analog lx=%d ly=%d rx=%d ry=%d l2=%d r2=%d db=%d ds=%d "
          "mx=%d gx=%d px=%d",
          lx, ly, rx, ry, l2, r2, derived_b, derived_start, mouse_x, gun_x,
          pointer_x);
  struct retro_message msg = {text, 1};
  env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
}

void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) {
  audio_batch_cb = cb;
}
void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb) { input_state_cb = cb; }

// Real cores log from retro_init and call the pointer without checking it, so
// the stub does the same to keep the host honest about GET_LOG_INTERFACE.
void retro_init(void) {
  frame_counter = 0;
  memset(controller_devices, 0, sizeof(controller_devices));
  // A restart reloads the core into the same process, and the host drains its
  // retired-value arena as part of that teardown, so a pointer stashed by the
  // previous session must not be carried into this one.
  stash_reset();
  struct retro_variable speed = {"stub_speed", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &speed);
  speed_fast = speed.value && strcmp(speed.value, "fast") == 0;
  struct retro_log_callback logging;
  memset(&logging, 0, sizeof(logging));
  env_cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging);
  log_cb = logging.log;
  logging.log(RETRO_LOG_DEBUG, "stub core init %d\n", 0);
}
void retro_deinit(void) {}
unsigned retro_api_version(void) { return RETRO_API_VERSION; }

void retro_get_system_info(struct retro_system_info *info) {
  memset(info, 0, sizeof(*info));
  info->library_name = "stub";
  info->library_version = "1.0";
  info->valid_extensions = "stub";
  info->need_fullpath = false;
}

void retro_get_system_av_info(struct retro_system_av_info *info) {
  memset(info, 0, sizeof(*info));
  info->geometry.base_width = STUB_WIDTH;
  info->geometry.base_height = STUB_HEIGHT;
  info->geometry.max_width = STUB_WIDTH;
  info->geometry.max_height = STUB_HEIGHT;
  info->geometry.aspect_ratio = (float)STUB_WIDTH / (float)STUB_HEIGHT;
  info->timing.fps = 60.0;
  info->timing.sample_rate = 44100.0;
}

// Packs 8-bit r/g/b into [dst] using [fmt], mirroring the host's unpack_pixel
// shifts exactly so a test can predict the converted value bit-for-bit.
static void write_pixel(uint8_t *dst, enum retro_pixel_format fmt, unsigned r,
                        unsigned g, unsigned b) {
  if (fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
    uint32_t word = (r << 16) | (g << 8) | b;
    memcpy(dst, &word, 4);
  } else if (fmt == RETRO_PIXEL_FORMAT_RGB565) {
    uint16_t word = (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
    memcpy(dst, &word, 2);
  } else {  // 0RGB1555
    uint16_t word = (uint16_t)(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3));
    memcpy(dst, &word, 2);
  }
}

bool retro_load_game(const struct retro_game_info *game) {
  shutdown_frame = 0;
  did_shutdown = 0;
  if (game && game->path) {
    size_t path_len = strlen(game->path);
    if (path_len >= 7 && strcmp(game->path + path_len - 7, "vfs.zip") == 0 &&
        !probe_vfs_zip(game->path)) {
      return false;
    }
  }
  if (game && game->data && game->size >= 6 &&
      memcmp(game->data, "reject", 6) == 0) {
    log_cb(RETRO_LOG_ERROR, "stub rejected this content\n");
    log_cb(RETRO_LOG_INFO, "stub finished rejection cleanup\n");
    return false;
  }
  if (game && game->data && game->size >= 8 &&
      memcmp(game->data, "shutdown", 8) == 0) {
    shutdown_frame = 3;
  }
  enum retro_pixel_format fmt = RETRO_PIXEL_FORMAT_XRGB8888;
  env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);

  struct retro_variable fmt_var = {"stub_format", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &fmt_var);
  if (fmt_var.value && strcmp(fmt_var.value, "rgb565") == 0) {
    pixel_fmt = RETRO_PIXEL_FORMAT_RGB565;
  } else if (fmt_var.value && strcmp(fmt_var.value, "0rgb1555") == 0) {
    pixel_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
  } else {
    pixel_fmt = RETRO_PIXEL_FORMAT_XRGB8888;
  }
  env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &pixel_fmt);

  struct retro_variable rot_var = {"stub_rotation", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &rot_var);
  unsigned rotation = rot_var.value ? (unsigned)atoi(rot_var.value) : 0;
  env_cb(RETRO_ENVIRONMENT_SET_ROTATION, &rotation);

  struct retro_variable pat_var = {"stub_pattern", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &pat_var);
  pattern_mode = pat_var.value && strcmp(pat_var.value, "on") == 0;

  struct retro_variable huge_var = {"stub_huge_frame", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &huge_var);
  huge_frame_mode = huge_var.value && strcmp(huge_var.value, "on") == 0;

  struct retro_variable pitch_var = {"stub_bad_pitch", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &pitch_var);
  bad_pitch_mode = pitch_var.value && strcmp(pitch_var.value, "on") == 0;

  struct retro_variable dircheck_var = {"stub_vfs_dir_check", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &dircheck_var);
  if (dircheck_var.value && strcmp(dircheck_var.value, "on") == 0) {
    probe_vfs_dir();
  }

  struct retro_variable analog_var = {"stub_analog_check", NULL};
  env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &analog_var);
  analog_check_mode = analog_var.value && strcmp(analog_var.value, "on") == 0;

  return true;
}

void retro_unload_game(void) {}

void retro_run(void) {
  stash_step();
  if (did_shutdown) {
    // A real core would fault here. Say so instead, so the harness can tell.
    struct retro_message late = {"stub ran after shutdown", 180};
    env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &late);
    return;
  }
  if (shutdown_frame > 0 && frame_counter >= shutdown_frame) {
    did_shutdown = 1;
    struct retro_message msg = {"stub boot failed", 180};
    env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
    env_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
    return;
  }
  input_poll_cb();
  int16_t mask =
      input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK);
  if (analog_check_mode) probe_analog();
  frame_counter += speed_fast ? 2 : 1;

  int bpp = pixel_fmt == RETRO_PIXEL_FORMAT_XRGB8888 ? 4 : 2;
  int pitch = STUB_WIDTH * bpp;

  // Reports a frame far past the host's LH_MAX_FRAME_DIMENSION bound. The
  // dimensions alone are what the host has to reject, so the real
  // framebuffer (sized for STUB_WIDTH*STUB_HEIGHT) is passed unchanged - the
  // host must never read pixel data out of it at these dimensions, only look
  // at width/height and refuse before touching the buffer.
  if (huge_frame_mode) {
    video_cb(framebuffer, 100000, 100000, pitch);
    return;
  }

  // Reports a valid, in-bounds frame size with a pitch too small to hold one
  // real scanline, so a host that doesn't check pitch against width*bpp would
  // read off the end of a real row into the next one (or past the buffer on
  // the last row).
  if (bad_pitch_mode) {
    video_cb(framebuffer, STUB_WIDTH, STUB_HEIGHT, 1);
    return;
  }

  if (pattern_mode) {
    // Coordinates encoded with different multipliers per axis (x*3, y*5) so a
    // transposed or mirrored rotation produces a detectably wrong pixel,
    // unlike a symmetric pattern which a 90-degree transpose could pass.
    for (int y = 0; y < STUB_HEIGHT; y++) {
      for (int x = 0; x < STUB_WIDTH; x++) {
        unsigned r = (unsigned)(x * 3) & 0xFF;
        unsigned g = (unsigned)(y * 5) & 0xFF;
        unsigned b = 0x11;
        write_pixel(framebuffer + (size_t)y * pitch + (size_t)x * bpp,
                   pixel_fmt, r, g, b);
      }
    }
  } else {
    // Encode the counter and input into the frame so the host's pixel
    // conversion and input plumbing can be checked end to end.
    unsigned r = (unsigned)(frame_counter & 0xFF);
    unsigned g = (unsigned)(mask & 0xFF);
    unsigned b = 0x55;
    for (int y = 0; y < STUB_HEIGHT; y++) {
      for (int x = 0; x < STUB_WIDTH; x++) {
        write_pixel(framebuffer + (size_t)y * pitch + (size_t)x * bpp,
                   pixel_fmt, r, g, b);
      }
    }
  }
  video_cb(framebuffer, STUB_WIDTH, STUB_HEIGHT, pitch);

  // One frame of a constant tone so the ring has something to read.
  int16_t samples[735 * 2];
  for (int i = 0; i < 735; i++) {
    samples[i * 2] = 1000;
    samples[i * 2 + 1] = -1000;
  }
  audio_batch_cb(samples, 735);
}

void retro_reset(void) { frame_counter = 0; }

size_t retro_serialize_size(void) { return sizeof(frame_counter) * 4; }

bool retro_serialize(void *data, size_t size) {
  if (size < sizeof(frame_counter) * 4) return false;
  int32_t *state = data;
  state[0] = frame_counter;
  state[1] = speed_fast;
  state[2] = stash_recheck;
  state[3] = (int32_t)controller_devices[0];
  return true;
}

bool retro_unserialize(const void *data, size_t size) {
  if (size < sizeof(frame_counter) * 3) return false;
  const int32_t *state = data;
  frame_counter = state[0];
  speed_fast = state[1];
  stash_recheck = state[2];
  return true;
}

void *retro_get_memory_data(unsigned id) {
  return id == RETRO_MEMORY_SAVE_RAM ? sram : NULL;
}
size_t retro_get_memory_size(unsigned id) {
  return id == RETRO_MEMORY_SAVE_RAM ? sizeof(sram) : 0;
}

// Unused libretro entry points.
void retro_set_controller_port_device(unsigned port, unsigned device) {
  if (port < 4) controller_devices[port] = device;
}
bool retro_load_game_special(unsigned type, const struct retro_game_info *info,
                             size_t num) {
  (void)type;
  (void)info;
  (void)num;
  return false;
}
unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
void retro_cheat_reset(void) {}
void retro_cheat_set(unsigned index, bool enabled, const char *code) {
  (void)index;
  (void)enabled;
  (void)code;
}
