package ru.rombica.indicator;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.droidlogic.app.SystemControlManager;

/**
 * Front LED roles for Rombica SmartBox A2: one role per colour of the bi-colour LED, stored in
 * persist.vendor.rombica.led.blue and .red. The properties are set through Amlogic's
 * systemcontrol (the vendor service apps use for display and device settings); init turns each
 * value into the kernel LED trigger of /sys/class/leds/sysled:blue or sysled:red
 * (/vendor/etc/init/rombica_a2.rc), at once and again at every boot.
 */
public class IndicatorActivity extends Activity {
    /** Property values, in the order of the "roles" labels (see rombica_a2.rc). */
    private static final String[] ROLES = {"off", "on", "heartbeat", "storage", "remote"};
    private static final String[] COLOURS = {"blue", "red"};
    private static final String[] DEFAULTS = {"on", "off"};     // the kernel's, like stock
    private static final String PROP = "persist.vendor.rombica.led.";

    private final String[] mRoles = DEFAULTS.clone();
    private ArrayAdapter<String> mAdapter;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int pad = (int) (48 * getResources().getDisplayMetrics().density);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad * 2, pad, pad * 2, pad);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(32);
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText(R.string.hint);
        hint.setTextSize(16);
        hint.setPadding(0, pad / 3, 0, pad / 2);
        root.addView(hint);

        load();
        mAdapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1);
        refresh();
        ListView list = new ListView(this);
        list.setAdapter(mAdapter);
        list.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                choose(position);
            }
        });
        root.addView(list, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(root);
        list.requestFocus();
    }

    private String colourLabel(int colour) {
        return getString(colour == 0 ? R.string.blue : R.string.red);
    }

    private void refresh() {
        String[] labels = getResources().getStringArray(R.array.roles);
        mAdapter.clear();
        for (int c = 0; c < COLOURS.length; c++) {
            mAdapter.add(colourLabel(c) + ": " + labels[indexOf(mRoles[c])]);
        }
    }

    private void choose(final int colour) {
        new AlertDialog.Builder(this)
                .setTitle(colourLabel(colour))
                .setSingleChoiceItems(R.array.roles, indexOf(mRoles[colour]),
                        new DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(DialogInterface dialog, int which) {
                                mRoles[colour] = ROLES[which];
                                save(colour);
                                refresh();
                                dialog.dismiss();
                            }
                        })
                .show();
    }

    private static int indexOf(String role) {
        for (int i = 0; i < ROLES.length; i++) {
            if (ROLES[i].equals(role)) return i;
        }
        return 0;
    }

    private void load() {
        SystemControlManager sc = SystemControlManager.getInstance();
        for (int c = 0; c < COLOURS.length; c++) {
            mRoles[c] = ROLES[indexOf(sc.getPropertyString(PROP + COLOURS[c], DEFAULTS[c]))];
        }
    }

    private void save(int colour) {
        SystemControlManager.getInstance().setProperty(PROP + COLOURS[colour], mRoles[colour]);
    }
}
