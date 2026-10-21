package dev.opencode.runleft;

import android.app.Activity;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.CountDownTimer;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/**
 * "Run Left" - a one-screen countdown to the end of a GitHub Actions run.
 *
 * Default target is the end of the keep-alive window of run 39528621597
 * (Roblox Player test (RDP + Tailscale)), i.e. 2026-10-21 13:29:14 UTC.
 * The target is editable and is persisted, so the same APK can be pointed at
 * any later deadline without a rebuild.
 */
public class MainActivity extends Activity {

    private static final String PREFS = "runleft";
    private static final String KEY_TARGET = "target_ms";

    private static final int BG = 0xFF0B0F14;
    private static final int FG = 0xFFE8EEF5;
    private static final int MUTED = 0xFF8A97A6;
    private static final int GREEN = 0xFF5BE49B;
    private static final int RED = 0xFFFF6B6B;

    private TextView captionView;
    private TextView bigView;
    private TextView targetView;
    private TextView utcView;
    private TextView nowView;

    private CountDownTimer timer;
    private long targetMs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        SharedPreferences prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        targetMs = prefs.getLong(KEY_TARGET, defaultTargetMs());
        buildUi();
        start();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (timer != null) {
            timer.cancel();
            timer = null;
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (timer == null) {
            start();
        }
    }

    /** End of the keep-alive window of run 39528621597 (hard-coded, in UTC). */
    private static long defaultTargetMs() {
        Calendar c = Calendar.getInstance(TimeZone.getTimeZone("UTC"));
        c.clear();
        c.set(2026, Calendar.OCTOBER, 21, 13, 29, 14);
        return c.getTimeInMillis();
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setBackgroundColor(BG);
        int pad = dp(22);
        root.setPadding(pad, pad, pad, pad);

        captionView = text("REMAINING", 13, MUTED, Typeface.DEFAULT_BOLD);
        captionView.setLetterSpacing(0.22f);
        root.addView(captionView);

        bigView = text("00:00:00", 46, GREEN, Typeface.MONOSPACE);
        bigView.setLetterSpacing(0.04f);
        bigView.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams bigLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        bigLp.topMargin = dp(10);
        bigLp.bottomMargin = dp(18);
        root.addView(bigView, bigLp);

        View rule = new View(this);
        rule.setBackgroundColor(0xFF1C2530);
        LinearLayout.LayoutParams ruleLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(1));
        root.addView(rule, ruleLp);

        targetView = text("", 15, FG, Typeface.DEFAULT);
        LinearLayout.LayoutParams tLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        tLp.topMargin = dp(18);
        root.addView(targetView, tLp);

        utcView = text("", 13, MUTED, Typeface.DEFAULT);
        root.addView(utcView);

        nowView = text("", 13, MUTED, Typeface.DEFAULT);
        nowView.setTypeface(Typeface.MONOSPACE);
        root.addView(nowView);

        TextView note = text("GitHub Actions · run 39528621597 · roblox-test · windows-2022",
                12, 0xFF55616E, Typeface.DEFAULT);
        note.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams noteLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        noteLp.topMargin = dp(26);
        root.addView(note, noteLp);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        rowLp.topMargin = dp(18);
        root.addView(buttons, rowLp);

        Button setBtn = button("Set target");
        setBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                pickTarget();
            }
        });
        buttons.addView(setBtn);

        Button resetBtn = button("Run end");
        resetBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                setTarget(defaultTargetMs());
            }
        });
        LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        resetLp.leftMargin = dp(10);
        buttons.addView(resetBtn, resetLp);

        setContentView(root);
    }

    private void pickTarget() {
        final Calendar c = Calendar.getInstance();
        c.setTimeInMillis(targetMs);
        new DatePickerDialog(this, new DatePickerDialog.OnDateSetListener() {
            @Override
            public void onDateSet(android.widget.DatePicker view, int year, int month, int dayOfMonth) {
                final Calendar t = Calendar.getInstance();
                t.setTimeInMillis(targetMs);
                t.set(year, month, dayOfMonth);
                new TimePickerDialog(MainActivity.this,
                        new TimePickerDialog.OnTimeSetListener() {
                            @Override
                            public void onTimeSet(android.widget.TimePicker view, int hourOfDay, int minute) {
                                t.set(Calendar.HOUR_OF_DAY, hourOfDay);
                                t.set(Calendar.MINUTE, minute);
                                t.set(Calendar.SECOND, 0);
                                t.set(Calendar.MILLISECOND, 0);
                                setTarget(t.getTimeInMillis());
                            }
                        }, t.get(Calendar.HOUR_OF_DAY), t.get(Calendar.MINUTE),
                        android.text.format.DateFormat.is24HourFormat(MainActivity.this)).show();
            }
        }, c.get(Calendar.YEAR), c.get(Calendar.MONTH), c.get(Calendar.DAY_OF_MONTH)).show();
    }

    private void setTarget(long ms) {
        targetMs = ms;
        SharedPreferences prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        prefs.edit().putLong(KEY_TARGET, ms).apply();
        start();
    }

    private void start() {
        if (timer != null) {
            timer.cancel();
        }
        long remaining = targetMs - System.currentTimeMillis();
        if (remaining < 0) {
            remaining = 0;
        }
        timer = new CountDownTimer(remaining, 250) {
            @Override
            public void onTick(long ms) {
                render(ms);
            }

            @Override
            public void onFinish() {
                render(0);
            }
        };
        timer.start();
    }

    private void render(long msLeft) {
        boolean expired = msLeft <= 0;
        bigView.setText(expired ? "00:00:00" : format(msLeft));
        bigView.setTextColor(expired ? RED : GREEN);
        captionView.setText(expired ? "EXPIRED" : "REMAINING");

        SimpleDateFormat local = new SimpleDateFormat("EEE d MMM yyyy  HH:mm:ss z", Locale.US);
        targetView.setText("Ends  " + local.format(new Date(targetMs)));

        SimpleDateFormat utc = new SimpleDateFormat("EEE d MMM yyyy  HH:mm:ss 'UTC'", Locale.US);
        utc.setTimeZone(TimeZone.getTimeZone("UTC"));
        utcView.setText("      " + utc.format(new Date(targetMs)));

        SimpleDateFormat now = new SimpleDateFormat("HH:mm:ss z", Locale.US);
        nowView.setText("now   " + now.format(new Date()) + "   (UTC " + utc.format(new Date()) + ")");
    }

    private static String format(long ms) {
        long total = ms / 1000;
        long h = total / 3600;
        long m = (total % 3600) / 60;
        long s = total % 60;
        return String.format(Locale.US, "%02d:%02d:%02d", h, m, s);
    }

    private TextView text(String s, int sp, int color, Typeface face) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setTypeface(face);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    private Button button(String label) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(13);
        b.setTextColor(FG);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        android.graphics.drawable.GradientDrawable bg =
                new android.graphics.drawable.GradientDrawable();
        bg.setColor(0xFF16202B);
        bg.setCornerRadius(dp(10));
        bg.setStroke(dp(1), 0xFF2A3948);
        b.setBackground(bg);
        b.setPadding(dp(16), dp(10), dp(16), dp(10));
        return b;
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
