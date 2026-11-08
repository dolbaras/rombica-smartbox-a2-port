/*
 * Rombica SmartBox A2: PC monitors (VESA modes) in SlimBOX's systemcontrol, the daemon that owns
 * the display output policy. SlimBOX's DisplayMode knows only TV modes.
 *
 * Output mode: getHdmiOutputMode() (best-mode policy) calls getHighestHdmiMode(), which ranks the
 * TV modes of disp_cap and so picks 720p on a 1280x1024 monitor. Now: if the sink's native mode
 * (marked '*' in disp_cap by the kernel, patch 0011) is a VESA mode "<w>x<h>p<rate>hz", that mode
 * is the output; otherwise the original ranking. TVs are unaffected (their native mode is a TV
 * mode). The user's own choice (not the best-mode policy) goes through filterHdmiMode() as before.
 *
 * OSD position (screen position settings, read by hwcomposer for the OSD window): getPosition()
 * and setPosition() keep ubootenv.var.<base>_x/_y/_w/_h per TV mode family ("720p", "1080p"...)
 * and fall back to "1080p" (1920x1080) for anything else, so a 1280x1024 picture got a 1920x1080
 * window. VESA modes now have their own keys, ubootenv.var.<mode>_x..., and default to their size.
 *
 * Colour format: with the best-mode policy on, getBestHdmiDeepColorAttr() takes the first entry of
 * its priority list (YCbCr 4:4:4 / 4:2:2 deep colour first, RGB last) that the sink lists in
 * dc_cap. For a PC monitor mode it is now RGB 8 bit, the format of VESA (IT) timings that every
 * HDMI sink must accept, as U-Boot and the kernel already set it: the picture keeps the format it
 * booted with (no second mode set) and the monitor gets full-range RGB. TV modes and a colour
 * format the user chose (best mode off: ubootenv.var.<mode>_deepcolor) are unaffected.
 */
#include "../common.h"

#define DISP_CAP "/sys/class/amhdmitx/amhdmitx0/disp_cap"
#define DC_CAP "/sys/class/amhdmitx/amhdmitx0/dc_cap"
#define RGB_8BIT "rgb,8bit"
#define TAG "rombica_sc"
#define MODE_LEN 64

/* in systemcontrol */
struct DisplayMode;
void orig_highest_hdmi_mode(struct DisplayMode *self, char *mode, void *data);
void orig_get_position(struct DisplayMode *self, const char *mode, int *position);
void orig_set_position(struct DisplayMode *self, const char *mode, int left, int top, int width,
		       int height);
void orig_best_color(struct DisplayMode *self, const char *mode, char *attr);
const char *bootenv_get(void *env, const char *key);           /* Ubootenv::getValue */
int set_boot_env(struct DisplayMode *self, const char *key, const char *value);
int pthread_mutex_lock(void *mutex);
int pthread_mutex_unlock(void *mutex);

/* members of DisplayMode, offsets from getPosition()/setPosition() */
#define ENV_LOCK(self) ((char *)(self) + 20)                     /* mEnvLock */
#define UBOOTENV(self) (*(void **)((char *)(self) + 296))        /* mUbootenv */

/* VESA mode name of at most MODE_LEN - 1 chars, else 0 */
static int vesa_name(const char *mode, unsigned *w, unsigned *h)
{
	int n = 0;

	while (mode[n] && mode[n] != '*' && mode[n] != '\n')
		if (++n >= MODE_LEN)
			return 0;
	return mode[n] == 0 && parse_vesa(mode, w, h) == 0;
}

void rombica_hdmi_mode(struct DisplayMode *self, char *mode, void *data)
{
	char cap[1024];
	const char *p;
	unsigned w, h;
	int n;

	if (read_file(DISP_CAP, cap, sizeof(cap)) > 0 && (p = native_mode(cap)) &&
	    parse_vesa(p, &w, &h) == 0) {
		for (n = 0; p[n] != '*' && n < MODE_LEN - 1; n++)
			mode[n] = p[n];
		mode[n] = 0;
		__android_log_print(ANDROID_LOG_INFO, TAG, "monitor: native mode %s", mode);
		return;
	}
	orig_highest_hdmi_mode(self, mode, data);
}

/* "ubootenv.var.<mode>_<c>" */
static void env_key(char *key, const char *mode, char c)
{
	static const char prefix[] = "ubootenv.var.";
	int i = 0;

	for (; prefix[i]; i++)
		key[i] = prefix[i];
	while (*mode)
		key[i++] = *mode++;
	key[i++] = '_';
	key[i++] = c;
	key[i] = 0;
}

static int env_int(struct DisplayMode *self, const char *mode, char c, int def)
{
	char key[MODE_LEN + 16];
	const char *v;

	env_key(key, mode, c);
	v = bootenv_get(UBOOTENV(self), key);
	return v ? atoi(v) : def;
}

void rombica_get_position(struct DisplayMode *self, const char *mode, int *position)
{
	unsigned w, h;

	if (!vesa_name(mode, &w, &h)) {
		orig_get_position(self, mode, position);
		return;
	}
	pthread_mutex_lock(ENV_LOCK(self));
	position[0] = env_int(self, mode, 'x', 0);
	position[1] = env_int(self, mode, 'y', 0);
	position[2] = env_int(self, mode, 'w', w);
	position[3] = env_int(self, mode, 'h', h);
	pthread_mutex_unlock(ENV_LOCK(self));      /* no log: hwcomposer asks on every frame */
}

void rombica_set_position(struct DisplayMode *self, const char *mode, int left, int top,
			  int width, int height)
{
	char key[MODE_LEN + 16], v[12];
	unsigned w, h;

	if (!vesa_name(mode, &w, &h)) {
		orig_set_position(self, mode, left, top, width, height);
		return;
	}
	pthread_mutex_lock(ENV_LOCK(self));
	env_key(key, mode, 'x');
	utoa(left, v);
	set_boot_env(self, key, v);
	env_key(key, mode, 'y');
	utoa(top, v);
	set_boot_env(self, key, v);
	env_key(key, mode, 'w');
	utoa(width, v);
	set_boot_env(self, key, v);
	env_key(key, mode, 'h');
	utoa(height, v);
	set_boot_env(self, key, v);
	pthread_mutex_unlock(ENV_LOCK(self));
	__android_log_print(ANDROID_LOG_INFO, TAG, "setPosition %s: %d %d %d %d", mode,
			    left, top, width, height);
}

/* dc_cap lists one colour format per line, e.g. "rgb,8bit" */
static int has_line(const char *cap, const char *line)
{
	const char *p = cap;
	int n;

	while (*p) {
		for (n = 0; line[n] && p[n] == line[n]; n++)
			;
		if (!line[n] && (p[n] == '\n' || p[n] == 0))
			return 1;
		while (*p && *p++ != '\n')
			;
	}
	return 0;
}

void rombica_best_color(struct DisplayMode *self, const char *mode, char *attr)
{
	char cap[512];
	unsigned w, h;
	int i;

	if (!vesa_name(mode, &w, &h) || read_file(DC_CAP, cap, sizeof(cap)) <= 0 ||
	    !has_line(cap, RGB_8BIT)) {
		orig_best_color(self, mode, attr);
		return;
	}
	for (i = 0; RGB_8BIT[i]; i++)
		attr[i] = RGB_8BIT[i];
	attr[i] = 0;
	__android_log_print(ANDROID_LOG_INFO, TAG, "monitor: %s colour format %s", mode, attr);
}
