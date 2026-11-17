package app.buddy.assistant;

import android.content.Context;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * One-tap follow-ups for the bubble (and share presets). Labels are short; {@link #prompt} is what gets sent.
 */
final class QuickActions {
    static final class Action {
        final String label;
        final String prompt;

        Action(String label, String prompt) {
            this.label = label;
            this.prompt = prompt;
        }
    }

    private QuickActions() {
    }

    /** Up to three chips above the bubble composer when the chat is idle. */
    static List<Action> forBubble(Context c, Sessions.Session ses, String foregroundApp) {
        List<Action> out = new ArrayList<>();
        if (ses == null) return out;
        String app = usableApp(c, foregroundApp);

        if (ses.messages.isEmpty()) {
            out.add(new Action(c.getString(R.string.quick_whats_on_screen),
                    c.getString(R.string.quick_prompt_whats_on_screen)));
            if (app != null) {
                out.add(new Action(c.getString(R.string.quick_help_with, app),
                        c.getString(R.string.quick_prompt_help_with, app)));
            } else {
                out.add(new Action(c.getString(R.string.quick_open_messages),
                        c.getString(R.string.quick_prompt_open_messages)));
            }
            if (TermuxRunner.installed(c)) {
                out.add(new Action(c.getString(R.string.quick_wifi_scan),
                        c.getString(R.string.quick_prompt_wifi_scan)));
            }
            return take(out, 3);
        }

        String lastUser = lastOf(ses, Bubble.Kind.USER);
        String low = lastUser == null ? "" : lastUser.toLowerCase(Locale.US);

        if (app != null) {
            out.add(new Action(c.getString(R.string.quick_continue_in, app),
                    c.getString(R.string.quick_prompt_continue_in, app)));
            if (looksLikeMessaging(app, low)) {
                out.add(new Action(c.getString(R.string.quick_reply_in, app),
                        c.getString(R.string.quick_prompt_reply_in, app)));
            }
        }
        if (looksLikeShopping(low) || looksLikeShopping(app)) {
            out.add(new Action(c.getString(R.string.quick_open_cart),
                    c.getString(R.string.quick_prompt_open_cart)));
        }
        out.add(new Action(c.getString(R.string.quick_do_again),
                c.getString(R.string.quick_prompt_do_again)));
        out.add(new Action(c.getString(R.string.quick_explain_briefly),
                c.getString(R.string.quick_prompt_explain_briefly)));
        if (TermuxRunner.installed(c) && out.size() < 3) {
            out.add(new Action(c.getString(R.string.quick_wifi_scan),
                    c.getString(R.string.quick_prompt_wifi_scan)));
        }
        return take(out, 3);
    }

    /** Share-sheet presets that wrap the shared text (or a short note when only files were shared). */
    static List<Action> forShare(Context c, String sharedText, boolean hasFiles) {
        String body = sharedText == null ? "" : sharedText.trim();
        String payload = body.isEmpty()
                ? (hasFiles ? c.getString(R.string.share_payload_files) : "")
                : body;
        List<Action> out = new ArrayList<>();
        if (payload.isEmpty()) {
            out.add(new Action(c.getString(R.string.share_action_just), ""));
            return out;
        }
        out.add(new Action(c.getString(R.string.share_action_summarize),
                c.getString(R.string.share_prompt_summarize, payload)));
        out.add(new Action(c.getString(R.string.share_action_reply_tone),
                c.getString(R.string.share_prompt_reply_tone, payload)));
        out.add(new Action(c.getString(R.string.share_action_calendar),
                c.getString(R.string.share_prompt_calendar, payload)));
        out.add(new Action(c.getString(R.string.share_action_just), payload));
        return out;
    }

    private static String lastOf(Sessions.Session ses, Bubble.Kind kind) {
        for (int i = ses.messages.size() - 1; i >= 0; i--) {
            Sessions.Msg m = ses.messages.get(i);
            if (m.kind == kind && m.text != null && !m.text.trim().isEmpty()) return m.text.trim();
        }
        return null;
    }

    private static String usableApp(Context c, String name) {
        if (name == null || name.trim().isEmpty()) return null;
        String n = name.trim();
        if (n.equalsIgnoreCase("Buddy") || n.equalsIgnoreCase(c.getString(R.string.app_name))) return null;
        return n;
    }

    private static boolean looksLikeMessaging(String app, String lastUser) {
        String a = app == null ? "" : app.toLowerCase(Locale.US);
        return a.contains("whatsapp") || a.contains("signal") || a.contains("telegram") || a.contains("messenger")
                || a.contains("messages") || a.contains("sms") || a.contains("discord") || a.contains("slack")
                || lastUser.contains("reply") || lastUser.contains("message") || lastUser.contains("whatsapp");
    }

    private static boolean looksLikeShopping(String s) {
        if (s == null || s.isEmpty()) return false;
        String a = s.toLowerCase(Locale.US);
        return a.contains("amazon") || a.contains("ebay") || a.contains("cart") || a.contains("shop")
                || a.contains("ali") || a.contains("store");
    }

    private static List<Action> take(List<Action> all, int n) {
        List<Action> out = new ArrayList<>();
        java.util.HashSet<String> seen = new java.util.HashSet<>();
        for (Action a : all) {
            if (a == null || a.label == null || a.prompt == null) continue;
            if (!seen.add(a.label)) continue;
            out.add(a);
            if (out.size() == n) break;
        }
        return out;
    }
}
