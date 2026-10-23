package com.tnxlive.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the `tnxlive/screen` bridge for Screen Live (v1.4).
 *
 * MethodChannel `tnxlive/screen`:
 *  - startScreen(cfg)   — full flow: start ScreenStreamService, show the
 *                         system MediaProjection consent dialog, then start
 *                         streaming. Replies "started" | "denied" |
 *                         "error:<detail>".
 *  - restartScreen(cfg) — reconnect on the existing projection (no dialog).
 *                         Replies "started" | "projectionDead" | "error:<…>".
 *  - stopScreen()       — stop stream + projection + service.
 *  - requestMicPermission() — replies true/false.
 *  - isProjectionActive()   — replies true/false.
 *
 * EventChannel `tnxlive/screen/events` streams the native ConnectChecker
 * events (connectionStarted/connectionSuccess/bitrate/connectionFailed/
 * disconnect/authError/projectionStopped) up to Dart.
 */
class MainActivity : FlutterActivity() {

  companion object {
    private const val RC_PROJECTION = 23177
    private const val RC_MIC = 23178
  }

  private val mainHandler = Handler(Looper.getMainLooper())

  private var pendingStartResult: MethodChannel.Result? = null
  private var pendingStartConfig: Map<String, Any?>? = null
  private var pendingMicResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val messenger = flutterEngine.dartExecutor.binaryMessenger

    EventChannel(messenger, "tnxlive/screen/events").setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
          ScreenStreamService.eventSink = { event -> events?.success(event) }
        }

        override fun onCancel(arguments: Any?) {
          ScreenStreamService.eventSink = null
        }
      }
    )

    MethodChannel(messenger, "tnxlive/screen").setMethodCallHandler { call, result ->
      when (call.method) {
        "startScreen" -> {
          @Suppress("UNCHECKED_CAST")
          val cfg = call.arguments as? Map<String, Any?> ?: emptyMap()
          startScreen(cfg, result)
        }
        "restartScreen" -> {
          val svc = ScreenStreamService.INSTANCE
          when {
            svc == null || !svc.hasProjection -> result.success("projectionDead")
            svc.restartStream() -> result.success("started")
            else -> result.success("error:restart failed")
          }
        }
        "stopScreen" -> {
          pendingStartResult?.success("error:cancelled")
          pendingStartResult = null
          pendingStartConfig = null
          ScreenStreamService.INSTANCE?.stopAll()
          result.success(true)
        }
        "isProjectionActive" -> {
          result.success(ScreenStreamService.INSTANCE?.hasProjection == true)
        }
        "requestMicPermission" -> requestMicPermission(result)
        else -> result.notImplemented()
      }
    }
  }

  private fun startScreen(cfg: Map<String, Any?>, result: MethodChannel.Result) {
    if (pendingStartResult != null) {
      result.success("error:busy")
      return
    }
    val svc = ScreenStreamService.INSTANCE
    if (svc != null && svc.hasProjection) {
      // A capture session is already alive (shouldn't normally happen —
      // Dart uses restartScreen for reconnects) — reuse it, no new dialog.
      result.success(if (svc.restartStream()) "started" else "error:restart failed")
      return
    }
    pendingStartResult = result
    pendingStartConfig = cfg
    ensureService { ready ->
      if (!ready) {
        pendingStartResult = null
        pendingStartConfig = null
        result.success("error:service unavailable")
        return@ensureService
      }
      val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
      try {
        startActivityForResult(mpm.createScreenCaptureIntent(), RC_PROJECTION)
      } catch (e: Exception) {
        pendingStartResult = null
        pendingStartConfig = null
        result.success("error:${e.message}")
      }
    }
  }

  /** Starts ScreenStreamService if needed and waits (briefly) for INSTANCE. */
  private fun ensureService(attempt: Int = 0, done: (Boolean) -> Unit) {
    if (ScreenStreamService.INSTANCE != null) {
      done(true)
      return
    }
    if (attempt == 0) {
      try {
        ContextCompat.startForegroundService(
          this,
          Intent(this, ScreenStreamService::class.java)
        )
      } catch (e: Exception) {
        done(false)
        return
      }
    }
    if (attempt >= 40) {
      done(false)
      return
    }
    mainHandler.postDelayed({ ensureService(attempt + 1, done) }, 100)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode != RC_PROJECTION) return
    val result = pendingStartResult
    val cfg = pendingStartConfig
    pendingStartResult = null
    pendingStartConfig = null
    if (result == null || cfg == null) return
    if (resultCode == Activity.RESULT_OK && data != null) {
      val svc = ScreenStreamService.INSTANCE
      if (svc == null) {
        result.success("error:service unavailable")
        return
      }
      val ok = svc.prepareAndStart(resultCode, data, cfg)
      result.success(if (ok) "started" else "error:prepare failed")
    } else {
      result.success("denied")
    }
  }

  private fun requestMicPermission(result: MethodChannel.Result) {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
      PackageManager.PERMISSION_GRANTED
    ) {
      result.success(true)
      return
    }
    if (pendingMicResult != null) {
      result.success(false)
      return
    }
    pendingMicResult = result
    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), RC_MIC)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode == RC_MIC) {
      val granted = grantResults.isNotEmpty() &&
        grantResults[0] == PackageManager.PERMISSION_GRANTED
      pendingMicResult?.success(granted)
      pendingMicResult = null
    }
  }
}
