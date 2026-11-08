package ru.rombica.indicator;

import android.app.Activity;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * Version and changelog of the Rombica A2 port: the build id, the running kernel and
 * /vendor/etc/rombica_port/CHANGELOG.txt (CHANGELOG.ru.txt for a Russian UI). Opened from
 * TvSettings ("project slimBOXtv" screen) and from the app list of a regular launcher.
 */
public class PortInfoActivity extends Activity {
    private static final String DIR = "/vendor/etc/rombica_port/";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int pad = (int) (48 * getResources().getDisplayMetrics().density);

        boolean ru = "ru".equals(Locale.getDefault().getLanguage());
        String changelog = read(DIR + (ru ? "CHANGELOG.ru.txt" : "CHANGELOG.txt"));
        if (changelog == null) changelog = read(DIR + "CHANGELOG.txt");
        String kernel = read("/proc/version");

        StringBuilder sb = new StringBuilder();
        sb.append(Build.DISPLAY).append("\n\n");
        if (kernel != null) sb.append(kernel.trim()).append("\n\n");
        sb.append(changelog != null ? changelog : getString(R.string.no_changelog));

        TextView text = new TextView(this);
        text.setText(sb);
        text.setTextSize(15);
        text.setTypeface(android.graphics.Typeface.MONOSPACE);
        text.setGravity(Gravity.START);

        // the scroll view itself takes focus, so the remote's up/down keys scroll the text
        ScrollView scroll = new ScrollView(this);
        scroll.setPadding(pad * 2, pad, pad * 2, pad);
        scroll.setClipToPadding(false);
        scroll.setFocusable(true);
        scroll.addView(text);
        setContentView(scroll);
        scroll.requestFocus();
    }

    private static String read(String path) {
        try (FileInputStream in = new FileInputStream(path)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
        }
    }
}
