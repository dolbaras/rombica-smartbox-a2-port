/*
 * Rombica SmartBox A2: the keyboard "like on a PC" for remote desktop clients, in SlimBOX's
 * libinputflinger (EventHub, which turns a key's scan/usage code into an Android key code).
 *
 * While the remote desktop mode is on (persist.vendor.mouse_touch_input=1: the switch in
 * slimBOXtv settings -> Mouse and keyboard), keyboards that use the generic key layout
 * (Generic.kl, i.e. ordinary USB/Bluetooth keyboards, not the IR remote) get key codes Android
 * does not act on for the keys Android or the Amlogic layout would take for themselves; the
 * client (RustDesk, RuDesktop in "Map" mode) still sends the real key by its scan code:
 *     Win (125, 126)  META_LEFT/RIGHT -> BREAK    Android: search, Win+x shortcuts
 *     Tab (15)        TAB -> BREAK                Android: Alt+Tab opens recent apps
 *     PrintScreen(99) SYSRQ -> BREAK              Android: screenshot
 *     Enter (28)      DPAD_CENTER -> ENTER        the Amlogic layout made it the remote's OK
 *     Home (HID usage 0x07004a)  HOME -> the scan code's key (MOVE_HOME): the Amlogic layout
 *                                sent the keyboard's Home to the launcher
 * The mode applies to the next key press, no device is reopened.
 */
#include "../common.h"
#include "../dynsym.h"

#define AKEYCODE_HOME 3
#define AKEYCODE_DPAD_CENTER 23
#define AKEYCODE_TAB 61
#define AKEYCODE_ENTER 66
#define AKEYCODE_META_LEFT 117
#define AKEYCODE_META_RIGHT 118
#define AKEYCODE_SYSRQ 120
#define AKEYCODE_BREAK 121
#define HID_USAGE_HOME 0x07004a

int pthread_mutex_lock(void *mutex);
int pthread_mutex_unlock(void *mutex);

/* in libinputflinger */
struct EventHub;
int orig_map_key(struct EventHub *hub, int device_id, int scan_code, int usage_code,
		 int meta_state, int *out_keycode, int *out_meta_state, unsigned *out_flags);
void *get_device_locked(struct EventHub *hub, int device_id);	/* EventHub::Device * */

#define HUB_LOCK(hub) ((char *)(hub) + 4)				/* EventHub::mLock */
#define DEVICE_KEY_LAYOUT_FILE(dev) (*(const char **)((char *)(dev) + 192))
							/* Device::keyMap.keyLayoutFile */

static int pc_mode(void)
{
	int (*get)(const char *name, char *value) = dynsym("libc.so", "__system_property_get");
	char v[PROP_VALUE_MAX];

	return get && get("persist.vendor.mouse_touch_input", v) > 0 && v[0] == '1' && !v[1];
}

static int generic_layout(struct EventHub *hub, int device_id)
{
	const char *kl = 0;
	void *dev;
	int r;

	pthread_mutex_lock(HUB_LOCK(hub));
	dev = get_device_locked(hub, device_id);
	if (dev)
		kl = DEVICE_KEY_LAYOUT_FILE(dev);
	r = kl && is_lib(kl, "Generic.kl");
	pthread_mutex_unlock(HUB_LOCK(hub));
	return r;
}

int rombica_map_key(struct EventHub *hub, int device_id, int scan_code, int usage_code,
		    int meta_state, int *out_keycode, int *out_meta_state, unsigned *out_flags)
{
	static const struct {
		unsigned char scan, from, to;
	} pc[] = {
		{125, AKEYCODE_META_LEFT, AKEYCODE_BREAK},
		{126, AKEYCODE_META_RIGHT, AKEYCODE_BREAK},
		{15, AKEYCODE_TAB, AKEYCODE_BREAK},
		{99, AKEYCODE_SYSRQ, AKEYCODE_BREAK},
		{28, AKEYCODE_DPAD_CENTER, AKEYCODE_ENTER},
	};
	int r = orig_map_key(hub, device_id, scan_code, usage_code, meta_state, out_keycode,
			     out_meta_state, out_flags);
	unsigned i;

	if (r || !pc_mode() || !generic_layout(hub, device_id))
		return r;
	if (usage_code == HID_USAGE_HOME && *out_keycode == AKEYCODE_HOME)
		return orig_map_key(hub, device_id, scan_code, 0, meta_state, out_keycode,
				    out_meta_state, out_flags);
	for (i = 0; i < sizeof(pc) / sizeof(pc[0]); i++)
		if (scan_code == pc[i].scan && *out_keycode == pc[i].from)
			*out_keycode = pc[i].to;
	return r;
}
