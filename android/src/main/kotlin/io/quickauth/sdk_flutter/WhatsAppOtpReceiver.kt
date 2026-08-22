package io.quickauth.sdk_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Receives a WhatsApp zero-tap or one-tap authentication code.
 *
 * <p>WhatsApp does not deliver these over SMS. It broadcasts to the app named in the
 * template's {@code supported_apps}, matched on package name and the 11-character signing
 * hash, so Google's SmsRetriever never sees the message and the code was previously dropped
 * on the floor.
 *
 * <p>Declared in the manifest rather than registered at runtime. Zero-tap's promise is that
 * the user does nothing, which means the code can arrive while the app is backgrounded or not
 * running at all — a runtime receiver only exists once the app already does, which is the case
 * that needs it least.
 *
 * <p>That in turn means the code can arrive with no Dart isolate to hand it to. It is held
 * here and flushed the moment something listens, so a cold start does not lose it.
 */
class WhatsAppOtpReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != ACTION_OTP_RETRIEVED) return

        // WhatsApp's own permission on the receiver keeps other apps out, but a code that is
        // absent or empty is worth ignoring quietly rather than surfacing as a blank OTP the
        // user cannot explain.
        val code = intent.getStringExtra(EXTRA_CODE)?.trim()
        if (code.isNullOrEmpty()) {
            Log.w(TAG, "WhatsApp OTP broadcast carried no code")
            return
        }

        Log.d(TAG, "WhatsApp OTP received (${code.length} chars)")
        deliver(code)
    }

    companion object {
        private const val TAG = "QuickAuthWaOtp"

        /**
         * WhatsApp's broadcast contract. Both zero-tap and one-tap arrive this way — one-tap
         * is the same delivery with a user tap in front of it — so one receiver serves both.
         *
         * <p>Kept as constants because a wrong value here fails in the worst way available:
         * the broadcast is simply never matched, nothing throws, and the OTP silently does not
         * arrive. Verify against Meta's current documentation when upgrading.
         */
        const val ACTION_OTP_RETRIEVED = "com.whatsapp.otp.OTP_RETRIEVED"
        const val EXTRA_CODE = "code"

        /**
         * The code, waiting for a listener.
         *
         * <p>Held rather than dropped because the receiver can fire before Flutter is alive.
         * Single-slot: a newer code always replaces an older one, which is what a user
         * requesting a second OTP expects, and it cannot grow without bound.
         */
        @Volatile
        private var pending: String? = null

        @Volatile
        private var listener: ((String) -> Unit)? = null

        /** Deliver now if something is listening, otherwise hold it. */
        @Synchronized
        fun deliver(code: String) {
            val target = listener
            if (target != null) target(code) else pending = code
        }

        /**
         * Attach the plugin's sink, and hand it anything that arrived while nothing was
         * listening. Taking the pending code rather than copying it means a code is delivered
         * once — a re-listen after a hot restart should not replay a code the user already
         * used.
         */
        @Synchronized
        fun setListener(target: ((String) -> Unit)?) {
            listener = target
            if (target == null) return
            val held = pending
            pending = null
            if (held != null) target(held)
        }

        /** Drop anything held. Called when a fresh OTP request starts. */
        @Synchronized
        fun clearPending() {
            pending = null
        }
    }
}
