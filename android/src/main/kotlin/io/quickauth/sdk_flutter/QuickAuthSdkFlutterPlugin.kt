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

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var smsReceiver: BroadcastReceiver? = null
    private var eventSink: EventChannel.EventSink? = null

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
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
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
        private const val METHOD_CHANNEL = "io.quickauth/sms_retriever"
        private const val EVENT_CHANNEL = "io.quickauth/sms_retriever/events"
        private const val HASH_LENGTH = 11
        private const val HASH_BYTES = 9
    }
}
