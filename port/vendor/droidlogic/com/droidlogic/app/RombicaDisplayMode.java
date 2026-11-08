package com.droidlogic.app;

/**
 * Rombica SmartBox A2 port: the display mode as the framework reads it from
 * persist.sys.display.resolution. Android's LocalDisplayAdapter (services.jar of SlimBOX) takes
 * "<height>p<rate>hz" from that property to find the display mode; OutputModeManager wrote the
 * output mode name itself, and PC monitor modes are named "<width>x<height>p<rate>hz" (so
 * parseInt("1280x1024") failed, the display was never configured and the mouse pointer stayed
 * at 0,0). 4096x2160 modes are named "smpte<rate>hz".
 *
 * Best mode (OutputModeManager.getHighestMatchResolution(), used by "Best resolution" in
 * TvSettings): SlimBOX ranks the modes of disp_cap by parseInt() of the name with 'p' -> '1',
 * which throws on PC monitor modes ("640x480p60hz" -> "640x480160") and crashed TvSettings. Now
 * the same policy as systemcontrol (vendor/native/systemcontrol): the sink's native mode (marked
 * '*' by the kernel) if it is a PC monitor mode, otherwise SlimBOX's ranking over the TV modes.
 */
final class RombicaDisplayMode {
    private RombicaDisplayMode() {
    }

    /** "<width>x<height>p<rate>hz" (a trailing '*' allowed) */
    static boolean isPcMode(String mode) {
        int x = mode.indexOf('x');
        int p = mode.indexOf('p');
        if (x <= 0 || p < x) {
            return false;
        }
        for (int i = 0; i < x; i++) {
            if (!Character.isDigit(mode.charAt(i))) {
                return false;
            }
        }
        return true;
    }

    /** the native mode of disp_cap without its '*' if it is a PC monitor mode, else null */
    static String nativePcMode(String[] modes) {
        for (String m : modes) {
            String t = m.trim();
            if (t.endsWith("*") && isPcMode(t)) {
                return t.substring(0, t.length() - 1);
            }
        }
        return null;
    }

    /** the TV modes of disp_cap, for SlimBOX's ranking */
    static String[] tvModes(String[] modes) {
        int n = 0;
        String[] tv = new String[modes.length];
        for (String m : modes) {
            if (!isPcMode(m.trim())) {
                tv[n++] = m;
            }
        }
        String[] r = new String[n];
        System.arraycopy(tv, 0, r, 0, n);
        return r;
    }

    static String resolution(String mode) {
        if (mode == null) {
            return null;
        }
        if (mode.startsWith("smpte")) {
            return "2160p" + mode.substring(5);
        }
        return isPcMode(mode) ? mode.substring(mode.indexOf('x') + 1) : mode;
    }
}
