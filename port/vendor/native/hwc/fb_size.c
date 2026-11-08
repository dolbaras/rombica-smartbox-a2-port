/*
 * Rombica SmartBox A2: size of the Android UI (framebuffer) for SlimBOX's hwcomposer.amlogic.so.
 * Replaces HwcConfig::getFramebufferSize(int disp, uint32_t &width, uint32_t &height), which in
 * SlimBOX knows only vendor.ui_mode "720"/"1080" and otherwise uses 1920x1080.
 *
 * hwcomposer fixes the UI size when it starts (FixedSizeModeMgr), so the decision belongs here:
 *   1. vendor.ui_mode "<width>x<height>" (or the old "720"/"1080") if set - an explicit choice;
 *   2. a PC monitor: the sink's native mode (marked '*' in disp_cap by the kernel, patch 0011) is a
 *      VESA mode "<w>x<h>p<rate>hz": the UI gets that size, scaled down into 1920x1200 with the
 *      same aspect for bigger modes (the GPU and memory are sized for 1080p UIs). The density is
 *      scaled with the width (qemu.sf.lcd_density, read by SurfaceFlinger), so the UI keeps the
 *      logical size it has on 1080p: ro.sf.lcd_density 240 at 1920 -> 160 at 1280;
 *   3. otherwise (TVs) 1920x1080, as before.
 * The output mode itself is chosen by systemcontrol (port/vendor/native/systemcontrol).
 */
#include "../common.h"

#define DISP_CAP "/sys/class/amhdmitx/amhdmitx0/disp_cap"
#define TAG "rombica_hwc"
#define MAX_W 1920
#define MAX_H 1200

static void fit(unsigned *w, unsigned *h)
{
	if (*w > MAX_W || *h > MAX_H) {
		if (*w * MAX_H > *h * MAX_W) {
			*h = *h * MAX_W / *w;
			*w = MAX_W;
		} else {
			*w = *w * MAX_H / *h;
			*h = MAX_H;
		}
	}
	*w &= ~1u;
	*h &= ~1u;
}

int rombica_fb_size(int disp, unsigned *width, unsigned *height)
{
	char value[PROP_VALUE_MAX];
	char cap[1024];
	unsigned w, h;
	const char *p;

	*width = 1920;
	*height = 1080;
	if (disp != 0)
		return 0;

	if (property_get("vendor.ui_mode", value, "") > 0) {
		if (parse_size(value, &w, &h) == 0) {
			*width = w;
			*height = h;
		} else if (!strncmp(value, "720", 3)) {
			*width = 1280;
			*height = 720;
		}
		__android_log_print(ANDROID_LOG_INFO, TAG, "UI %ux%u (vendor.ui_mode %s)",
				    *width, *height, value);
		return 0;
	}

	if (read_file(DISP_CAP, cap, sizeof(cap)) <= 0)
		return 0;
	p = native_mode(cap);
	if (!p || parse_vesa(p, &w, &h))
		return 0;
	fit(&w, &h);
	*width = w;
	*height = h;

	if (property_get("ro.sf.lcd_density", value, "240") > 0) {
		unsigned d = atoi(value) * w / 1920;
		char s[12];

		utoa(d < 120 ? 120 : d, s);
		property_set("qemu.sf.lcd_density", s);
	}
	__android_log_print(ANDROID_LOG_INFO, TAG, "monitor, native mode %.16s: UI %ux%u", p, w, h);
	return 0;
}
