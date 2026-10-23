package com.tnxlive.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.encoder.input.sources.audio.NoAudioSource
import com.pedro.encoder.input.sources.video.NoVideoSource
import com.pedro.encoder.input.sources.video.ScreenSource
import com.pedro.library.generic.GenericStream
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Screen Live engine (v1.4): MediaProjection screen capture -> H.264/AAC ->
 * RTMP via RootEncoder's GenericStream. Modelled on RootEncoder 2.8.1's own
 * screen demo service (same library, Apache-2.0).
 *
 * The service is the mediaProjection-type foreground service Android 14
 * requires to be running before createVirtualDisplay. It owns the
 * MediaProjection for the whole session, so an RTMP-layer drop can be
 * restarted (restartStream) without a new system consent dialog — the
 * projection (and its consent) stays alive until stopAll().
 *
 * All library events are forwarded to Dart through [eventSink] (installed by
 * MainActivity's EventChannel) as maps: {type, ...}. Dart owns the policy
 * (alert, backoff/reconnect, schedule accounting) exactly like video mode.
 */
@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
class ScreenStreamService : Service(), ConnectChecker {

  companion object {
    private const val TAG = "TNxScreenService"
    private const val CHANNEL_ID = "tnxlive_screen_capture"
    private const val NOTIF_ID = 4321

    var INSTANCE: ScreenStreamService? = null

    /** Installed by MainActivity; receives event maps on the main thread. */
    @Volatile
    var eventSink: ((Map<String, Any?>) -> Unit)? = null
  }

  private val mainHandler = Handler(Looper.getMainLooper())
  private val mediaProjectionManager: MediaProjectionManager by lazy {
    applicationContext.getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
  }

  private var stream: GenericStream? = null
  private var mediaProjection: MediaProjection? = null
  private var sessionUrl: String? = null
  private var stoppingAll = false

  val hasProjection: Boolean
    get() = mediaProjection != null

  val isStreamingNow: Boolean
    get() = stream?.isStreaming == true

  override fun onCreate() {
    super.onCreate()
    val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_ID, "TNxLive Screen Live", NotificationManager.IMPORTANCE_LOW)
      )
    }
    // Android requires the mediaProjection FGS to be foregrounded promptly
    // after startForegroundService — do it here, before any consent exists.
    goForeground(includeMic = false)
    INSTANCE = this
    Log.i(TAG, "Screen service created")
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

  override fun onDestroy() {
    stopStreamInternal()
    try {
      stream?.release()
    } catch (_: Exception) {
    }
    stream = null
    try {
      mediaProjection?.stop()
    } catch (_: Exception) {
    }
    mediaProjection = null
    INSTANCE = null
    super.onDestroy()
  }

  private fun goForeground(includeMic: Boolean) {
    val notif = NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(applicationInfo.icon)
      .setContentTitle("TNxLive — Screen Live")
      .setContentText("Screen stream cholche")
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (includeMic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        startForeground(NOTIF_ID, notif, type)
      } else {
        startForeground(NOTIF_ID, notif)
      }
    } catch (e: Exception) {
      Log.w(TAG, "startForeground failed: ${e.message}")
    }
  }

  private fun emit(type: String, extra: Map<String, Any?> = emptyMap()) {
    val sink = eventSink ?: return
    val event = HashMap<String, Any?>()
    event["type"] = type
    event.putAll(extra)
    mainHandler.post { sink(event) }
  }

  /**
   * Fresh session start, called by MainActivity right after the user grants
   * the MediaProjection consent dialog. cfg keys: url, audio ('mic'|'mute'),
   * shortEdge (Int), videoBitrate (Int bps). Returns false if the encoder
   * could not be prepared or the projection could not be created.
   */
  fun prepareAndStart(resultCode: Int, data: Intent, cfg: Map<String, Any?>): Boolean {
    val url = cfg["url"] as? String ?: return false
    val mic = (cfg["audio"] as? String) == "mic"
    val shortEdge = (cfg["shortEdge"] as? Number)?.toInt() ?: 720
    val videoBitrate = (cfg["videoBitrate"] as? Number)?.toInt() ?: 2_500_000

    stoppingAll = false
    goForeground(includeMic = mic)
    stopStreamInternal()
    try {
      mediaProjection?.stop()
    } catch (_: Exception) {
    }
    mediaProjection = null

    val mp = try {
      mediaProjectionManager.getMediaProjection(resultCode, data)
    } catch (e: Exception) {
      Log.w(TAG, "getMediaProjection failed: ${e.message}")
      return false
    } ?: return false
    mediaProjection = mp

    // (Re)build the stream with this session's sources. The GenericStream is
    // created once per service lifetime; audio choice is fixed per session
    // because stopAll() destroys the service between sessions.
    var s = stream
    if (s == null) {
      s = GenericStream(
        applicationContext,
        this,
        NoVideoSource(),
        if (mic) MicrophoneSource() else NoAudioSource()
      ).apply {
        // MediaProjection only produces frames when the screen changes —
        // force a constant render fps so the stream keeps flowing on a
        // static screen (RootEncoder's screen demo does the same).
        getGlInterface().setForceRender(true, 15)
      }
      stream = s
    }

    val (encW, encH, rotation) = computeEncoderSize(shortEdge)
    val prepared = try {
      s.prepareVideo(encW, encH, videoBitrate, fps = 30, rotation = rotation) &&
        s.prepareAudio(44100, true, 128_000, echoCanceler = mic, noiseSuppressor = mic)
    } catch (e: IllegalArgumentException) {
      Log.w(TAG, "prepare failed: ${e.message}")
      false
    } catch (e: IllegalStateException) {
      Log.w(TAG, "prepare failed: ${e.message}")
      false
    }
    if (!prepared) return false

    val projectionCallback = object : MediaProjection.Callback() {
      override fun onStop() {
        // The user stopped the capture from the system UI (or the system
        // revoked it). The consent token is dead — Dart must not retry
        // against it; it will end the session and ask for a fresh grant on
        // the next manual START.
        if (stoppingAll) return
        mediaProjection = null
        emit("projectionStopped")
      }
    }
    return try {
      s.changeVideoSource(ScreenSource(applicationContext, mp, projectionCallback))
      sessionUrl = url
      s.startStream(url)
      true
    } catch (e: Exception) {
      Log.w(TAG, "startStream failed: ${e.message}")
      false
    }
  }

  /**
   * Reconnect path used by Dart's backoff: re-runs startStream on the SAME
   * MediaProjection (no new consent dialog). Returns false when the capture
   * session is gone and only a fresh user grant can start again.
   */
  fun restartStream(): Boolean {
    val s = stream ?: return false
    val url = sessionUrl ?: return false
    if (mediaProjection == null) return false
    return try {
      if (s.isStreaming) s.stopStream()
      s.startStream(url)
      true
    } catch (e: Exception) {
      Log.w(TAG, "restartStream failed: ${e.message}")
      false
    }
  }

  /** Deliberate full stop: stream + projection + service. */
  fun stopAll() {
    stoppingAll = true
    stopStreamInternal()
    try {
      mediaProjection?.stop()
    } catch (_: Exception) {
    }
    mediaProjection = null
    sessionUrl = null
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    stopSelf()
  }

  private fun stopStreamInternal() {
    try {
      val s = stream
      if (s != null && s.isStreaming) s.stopStream()
    } catch (_: Exception) {
    }
  }

  /**
   * prepareVideo() takes (longEdge, shortEdge) plus a rotation: with
   * rotation = 90 the encoder and the virtual display come out portrait
   * (shortEdge x longEdge). The short edge is capped by the quality setting
   * and never upscales past the real screen; both dims are kept even
   * (ScreenSource requires width/height divisible by 2).
   */
  private fun computeEncoderSize(shortEdgeTarget: Int): Triple<Int, Int, Int> {
    val metrics = applicationContext.resources.displayMetrics
    val w = metrics.widthPixels
    val h = metrics.heightPixels
    val portrait = h >= w
    val nativeShort = min(w, h)
    val nativeLong = maxOf(w, h)
    val targetShort = min(shortEdgeTarget, nativeShort)
    val scale = if (nativeShort > 0) targetShort.toDouble() / nativeShort else 1.0
    var targetLong = (nativeLong * scale).roundToInt()
    if (targetLong % 2 != 0) targetLong -= 1
    val ts = targetShort - (targetShort % 2)
    return Triple(targetLong, ts, if (portrait) 90 else 0)
  }

  // ---- ConnectChecker: forward everything to Dart; Dart owns the policy ----

  override fun onConnectionStarted(url: String) {
    emit("connectionStarted", mapOf("url" to url))
  }

  override fun onConnectionSuccess() {
    emit("connectionSuccess")
  }

  override fun onNewBitrate(bitrate: Long) {
    val bytes = try {
      stream?.getStreamClient()?.getBytesSend() ?: 0L
    } catch (_: Exception) {
      0L
    }
    emit("bitrate", mapOf("bitrate" to bitrate, "bytes" to bytes))
  }

  override fun onConnectionFailed(reason: String) {
    // Terminal for this attempt (same as RootEncoder's demo): reset the
    // stream object so a later startStream works, keep the projection.
    stopStreamInternal()
    emit("connectionFailed", mapOf("reason" to reason))
  }

  override fun onDisconnect() {
    emit("disconnect")
  }

  override fun onAuthError() {
    stopStreamInternal()
    emit("authError")
  }

  override fun onAuthSuccess() {
    emit("authSuccess")
  }
}
