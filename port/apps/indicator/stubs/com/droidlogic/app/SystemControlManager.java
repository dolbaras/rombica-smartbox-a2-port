package com.droidlogic.app;

/**
 * Compile-time stub of the part of Amlogic's SystemControlManager (droidlogic.jar, shared
 * library "droidlogic.software.core" in /vendor/framework) the Indicator app uses. Not packaged:
 * at run time the class comes from the device's library (uses-library in the manifest).
 * The calls go to the systemcontrol daemon, which sets the property with its own rights.
 */
public class SystemControlManager {
    public static SystemControlManager getInstance() {
        throw new RuntimeException("stub");
    }

    public String getPropertyString(String key, String def) {
        throw new RuntimeException("stub");
    }

    public void setProperty(String key, String value) {
        throw new RuntimeException("stub");
    }
}
