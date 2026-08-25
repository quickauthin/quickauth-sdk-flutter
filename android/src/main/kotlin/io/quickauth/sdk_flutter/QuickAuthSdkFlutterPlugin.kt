package io.quickauth.sdk_flutter

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.auth.api.phone.SmsRetrieverClient
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/**
 * QuickAuth Flutter plugin — Android side.
 *
 * Method channel: `io.quickauth/sms_retriever`
 *   - `start`        → registers SmsRetriever, returns true on success
 *   - `getAppHash`   → returns 11-char app-signing hash
 *   - `launchUrl`    → opens an external URL (used for WhatsApp deep-link)
 *
 * Event channel: `io.quickauth/sms_retriever/events`
 *   - emits the full SMS body whenever an OTP message arrives.
 */
class QuickAuthSdkFlutterPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    // The receiver runs on a binder thread; Flutter sinks must be touched from main.
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var smsReceiver: BroadcastReceiver? = null
    private var eventSink: EventChannel.EventSink? = null
    private lateinit var waEventChannel: EventChannel
    private var waEventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        waEventChannel = EventChannel(binding.binaryMessenger, WA_EVENT_CHANNEL)
        waEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                waEventSink = events
                // Attaching also flushes anything the receiver caught while Flutter was not
                // running — the zero-tap case this whole path exists for.
                WhatsAppOtpReceiver.setListener { code ->
                    mainHandler.post { waEventSink?.success(code) }
                }
            }

            override fun onCancel(arguments: Any?) {
                WhatsAppOtpReceiver.setListener(null)
                waEventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        waEventChannel.setStreamHandler(null)
        WhatsAppOtpReceiver.setListener(null)
        unregisterReceiver()
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> startSmsRetriever(result)
            "getAppHash" -> result.success(getAppHashes().firstOrNull())
            // Called when a fresh OTP is requested, so a code held from an earlier attempt
            // cannot be delivered against the new one.
            "sendWhatsAppOtpHandshake" -> result.success(sendHandshakeToWhatsApp())
            "clearWhatsAppOtp" -> {
                WhatsAppOtpReceiver.clearPending()
                result.success(true)
            }
            "launchUrl" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("invalid_args", "url required", null)
                } else {
                    result.success(launchUrl(url))
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Tell WhatsApp we are about to request a code, and that this app may receive it.
     *
     * <p>Zero-tap does not work without this, and nothing says so. Meta requires the app to
     * broadcast a handshake BEFORE the template is sent: "When a user in your app requests a
     * password or code to be delivered to their WhatsApp number, first initiate the handshake,
     * then call our API to send the authentication template message."
     *
     * <p>Without it WhatsApp receives the message and shows it, and simply never broadcasts
     * the code. Every other check can pass — template approved, package matching, signing hash
     * matching, receiver registered and firing — and the OTP still does not auto-fill, with no
     * error anywhere to explain it.
     *
     * <p>The PendingIntent in {@code _ci_} is how WhatsApp identifies the caller. It carries no
     * action and is never sent; WhatsApp reads the creator's identity off it, which is why it
     * must be immutable — a mutable one would let another app fill it in.
     *
     * <p>Broadcast to both WhatsApp and WhatsApp Business, because the user's code arrives on
     * whichever they have. Sending to a package that is not installed is a no-op rather than an
     * error, so there is nothing to check first.
     *
     * <p>The handshake expires after ten minutes, so it is sent per OTP request rather than
     * once at startup.
     *
     * @return the request id, which the receiver echoes back so a caller can tie a delivered
     *         code to the request that asked for it
     */
    private fun sendHandshakeToWhatsApp(): String? {
        val ctx = context ?: return null
        return try {
            val requestId = java.util.UUID.randomUUID().toString()
            // No action and FLAG_IMMUTABLE: this is an identity token, not something to fire.
            val identity = android.app.PendingIntent.getBroadcast(
                ctx, 0, Intent(),
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            )
            // Which WhatsApp packages this app can actually see. On API 30+ an invisible
            // package swallows the broadcast silently, so reporting it is the difference
            // between diagnosing that in one log line and chasing the template for a day.
            val visible = WHATSAPP_PACKAGES.filter { pkg ->
                try {
                    ctx.packageManager.getPackageInfo(pkg, 0)
                    true
                } catch (e: PackageManager.NameNotFoundException) {
                    false
                }
            }

            for (pkg in WHATSAPP_PACKAGES) {
                val intent = Intent(ACTION_OTP_REQUESTED).setPackage(pkg)
                intent.putExtra("_ci_", identity)
                intent.putExtra("request_id", requestId)
                ctx.sendBroadcast(intent)
            }

            if (visible.isEmpty()) {
                // Either WhatsApp is not installed, or <queries> is missing from the merged
                // manifest. Both mean the handshake reached nobody and zero-tap cannot work.
                Log.w(WA_TAG, "WhatsApp OTP handshake sent but NO WhatsApp package is visible "
                        + "— not installed, or <queries> missing from the merged manifest")
            } else {
                Log.d(WA_TAG, "WhatsApp OTP handshake sent to $visible (requestId=$requestId)")
            }
            requestId
        } catch (t: Throwable) {
            // Never fail the OTP request over this. A missing handshake costs auto-read, not
            // the login — the user can still read the code and type it.
            Log.w(WA_TAG, "WhatsApp OTP handshake failed: ${t.message}")
            null
        }
    }

    private fun startSmsRetriever(result: Result) {
        val ctx = context
        if (ctx == null) {
            result.success(false)
            return
        }
        try {
            val client: SmsRetrieverClient = SmsRetriever.getClient(ctx)
            client.startSmsRetriever()
                .addOnSuccessListener {
                    registerReceiver()
                    result.success(true)
                }
                .addOnFailureListener { e ->
                    Log.w(TAG, "SmsRetriever start failed: ${e.message}")
                    result.success(false)
                }
        } catch (t: Throwable) {
            Log.w(TAG, "SmsRetriever exception", t)
            result.success(false)
        }
    }

    private fun registerReceiver() {
        if (smsReceiver != null) return
        val ctx = context ?: return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                if (intent?.action != SmsRetriever.SMS_RETRIEVED_ACTION) return
                val extras: Bundle = intent.extras ?: return
                val status = extras.get(SmsRetriever.EXTRA_STATUS) as? Status
                if (status?.statusCode == CommonStatusCodes.SUCCESS) {
                    val body = extras.getString(SmsRetriever.EXTRA_SMS_MESSAGE)
                    if (!body.isNullOrEmpty()) {
                        eventSink?.success(body)
                    }
                }
            }
        }
        val filter = IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, filter)
        }
        smsReceiver = receiver
    }

    private fun unregisterReceiver() {
        smsReceiver?.let { rec ->
            try {
                context?.unregisterReceiver(rec)
            } catch (_: IllegalArgumentException) {
                // already unregistered
            }
        }
        smsReceiver = null
    }

    private fun launchUrl(url: String): Boolean {
        val act = activity ?: context ?: return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            if (act !is Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            act.startActivity(intent)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "launchUrl failed", t)
            false
        }
    }

    /**
     * Computes the 11-char Google SmsRetriever app-signing hash for every
     * signature on the package. Mirrors the upstream sample at
     * https://developers.google.com/identity/sms-retriever/verify
     */
    private fun getAppHashes(): List<String> {
        val ctx = context ?: return emptyList()
        val pkg = ctx.packageName
        val pm = ctx.packageManager
        val signatures: Array<Signature> = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(
                    pkg,
                    PackageManager.GET_SIGNING_CERTIFICATES
                )
                info.signingInfo?.apkContentsSigners ?: emptyArray()
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures
                    ?: emptyArray()
            }
        } catch (_: Throwable) {
            emptyArray()
        }
        val out = mutableListOf<String>()
        for (sig in signatures) {
            val hash = hash(pkg, sig.toCharsString()) ?: continue
            out += hash
        }
        return out
    }

    private fun hash(pkg: String, signature: String): String? {
        val appInfo = "$pkg $signature"
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            val bytes = md.digest(appInfo.toByteArray(StandardCharsets.UTF_8))
            val truncated = bytes.copyOfRange(0, HASH_BYTES)
            Base64.encodeToString(truncated, Base64.NO_PADDING or Base64.NO_WRAP)
                .substring(0, HASH_LENGTH)
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        private const val TAG = "QuickAuthSdk"

        /**
         * The WhatsApp auto-read tag, shared with WhatsAppOtpReceiver.
         *
         * <p>The handshake logged under the plugin's own tag while the receiver logged under
         * its own, so filtering on either showed half the exchange. Someone watching
         * QuickAuthWaOtp — which is the tag worth watching, since it is the one the receiver
         * uses — saw nothing at all when the handshake fired and read that as the handshake
         * never happening. Both halves of one feature, one tag.
         */
        private const val WA_TAG = "QuickAuthWaOtp"
        private const val METHOD_CHANNEL = "io.quickauth/sms_retriever"
        private const val EVENT_CHANNEL = "io.quickauth/sms_retriever/events"

        /**
         * WhatsApp codes go on their own channel rather than joining the SMS stream.
         *
         * <p>The SMS channel emits a whole message body, which Dart then parses for a code.
         * WhatsApp hands over the code itself. Putting both on one channel would mean the
         * Dart side could not tell a body from a code without inspecting it, and every
         * existing listener would start receiving a shape it was never written for.
         */
        private const val WA_EVENT_CHANNEL = "io.quickauth/whatsapp_otp/events"

        /** Meta's handshake action, broadcast to WhatsApp before the template is sent. */
        private const val ACTION_OTP_REQUESTED = "com.whatsapp.otp.OTP_REQUESTED"

        /** Consumer WhatsApp and WhatsApp Business — the code arrives on whichever is installed. */
        private val WHATSAPP_PACKAGES = listOf("com.whatsapp", "com.whatsapp.w4b")
        private const val HASH_LENGTH = 11
        private const val HASH_BYTES = 9
    }
}
