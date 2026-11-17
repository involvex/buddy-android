package app.buddy.assistant;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;

import androidx.core.content.ContextCompat;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Runs a shell command in the user's InVxTermux install via its exported RUN_COMMAND service.
 * Requires the dangerous {@code com.involvex.termux_app.permission.RUN_COMMAND} grant and
 * {@code allow-external-apps=true} in Termux's {@code ~/.termux/termux.properties}.
 */
final class TermuxRunner {
    static final String PACKAGE = "com.involvex.termux_app";
    static final String PERMISSION = PACKAGE + ".permission.RUN_COMMAND";
    private static final String SERVICE = PACKAGE + ".app.RunCommandService";
    private static final String ACTION = PACKAGE + ".RUN_COMMAND";
    private static final String EXTRA_COMMAND_PATH = PACKAGE + ".RUN_COMMAND_PATH";
    private static final String EXTRA_STDIN = PACKAGE + ".RUN_COMMAND_STDIN";
    private static final String EXTRA_WORKDIR = PACKAGE + ".RUN_COMMAND_WORKDIR";
    private static final String EXTRA_BACKGROUND = PACKAGE + ".RUN_COMMAND_BACKGROUND";
    private static final String EXTRA_PENDING_INTENT = PACKAGE + ".RUN_COMMAND_PENDING_INTENT";
    private static final String EXTRA_RESULT_BUNDLE = "result";
    private static final String RESULT_STDOUT = "stdout";
    private static final String RESULT_STDERR = "stderr";
    private static final String RESULT_EXIT = "exitCode";
    private static final String RESULT_ERRMSG = "errmsg";
    private static final String SH = "/data/data/" + PACKAGE + "/files/usr/bin/sh";
    private static final String CALLBACK_ACTION = "app.buddy.assistant.TERMUX_RUN_RESULT";

    static final class Result {
        final int exitCode;
        final String stdout;
        final String stderr;
        final String error;

        Result(int exitCode, String stdout, String stderr, String error) {
            this.exitCode = exitCode;
            this.stdout = stdout == null ? "" : stdout;
            this.stderr = stderr == null ? "" : stderr;
            this.error = error == null ? "" : error;
        }
    }

    private TermuxRunner() {
    }

    static boolean installed(Context c) {
        try {
            c.getPackageManager().getPackageInfo(PACKAGE, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    static boolean hasPermission(Context c) {
        return ContextCompat.checkSelfPermission(c, PERMISSION) == PackageManager.PERMISSION_GRANTED;
    }

    /**
     * Runs {@code command} via {@code sh} in Termux (stdin). Blocks up to {@code timeoutSec}.
     * Call from a worker thread, not the main thread.
     */
    static Result exec(Context c, String command, String workdir, int timeoutSec) throws Exception {
        if (!installed(c)) {
            return new Result(-1, "", "", "InVxTermux (" + PACKAGE + ") is not installed.");
        }
        if (!hasPermission(c)) {
            return new Result(-1, "", "", "Buddy needs the RUN_COMMAND permission for InVxTermux. "
                    + "Grant it when asked, or enable it in Android Settings → Apps → Buddy → Permissions.");
        }
        final Context app = c.getApplicationContext();
        final String token = Long.toHexString(System.nanoTime());
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicReference<Result> out = new AtomicReference<>();

        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null || !token.equals(intent.getStringExtra("buddy_token"))) return;
                Bundle b = intent.getBundleExtra(EXTRA_RESULT_BUNDLE);
                if (b == null) b = intent.getExtras() == null ? new Bundle() : intent.getExtras();
                int code = b.containsKey(RESULT_EXIT) ? b.getInt(RESULT_EXIT) : -1;
                String err = b.getString(RESULT_ERRMSG, "");
                out.set(new Result(code, b.getString(RESULT_STDOUT, ""), b.getString(RESULT_STDERR, ""), err));
                done.countDown();
            }
        };

        IntentFilter filter = new IntentFilter(CALLBACK_ACTION);
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            app.registerReceiver(receiver, filter);
        }

        try {
            Intent callback = new Intent(CALLBACK_ACTION);
            callback.setPackage(app.getPackageName());
            callback.putExtra("buddy_token", token);
            int flags = PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags |= PendingIntent.FLAG_MUTABLE;
            PendingIntent pi = PendingIntent.getBroadcast(app, token.hashCode(), callback, flags);

            Intent run = new Intent();
            run.setClassName(PACKAGE, SERVICE);
            run.setAction(ACTION);
            run.putExtra(EXTRA_COMMAND_PATH, SH);
            run.putExtra(EXTRA_STDIN, command);
            run.putExtra(EXTRA_BACKGROUND, true);
            if (workdir != null && !workdir.isEmpty()) run.putExtra(EXTRA_WORKDIR, workdir);
            run.putExtra(EXTRA_PENDING_INTENT, pi);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                app.startForegroundService(run);
            } else {
                app.startService(run);
            }

            if (!done.await(Math.max(1, timeoutSec), TimeUnit.SECONDS)) {
                return new Result(-1, "", "", "Timed out after " + timeoutSec + " s waiting for Termux. "
                        + "If Termux showed a notification about external apps, set allow-external-apps=true in "
                        + "~/.termux/termux.properties and retry.");
            }
            Result r = out.get();
            if (r == null) {
                return new Result(-1, "", "", "No result from Termux.");
            }
            if (!r.error.isEmpty() && r.stdout.isEmpty() && r.stderr.isEmpty()) {
                // errmsg often explains allow-external-apps / permission policy
                return r;
            }
            return r;
        } finally {
            try {
                app.unregisterReceiver(receiver);
            } catch (Exception ignored) {
            }
        }
    }

    /** Request RUN_COMMAND on the UI thread if missing (no-op when already granted). */
    static void requestPermission(android.app.Activity a) {
        if (hasPermission(a)) return;
        if (Build.VERSION.SDK_INT >= 23) {
            a.requestPermissions(new String[]{PERMISSION}, 8742);
        }
    }
}
