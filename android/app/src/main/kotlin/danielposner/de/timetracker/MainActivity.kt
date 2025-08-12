package danielposner.de.timetracker

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val channelName = "focus_mode"
    private val ttChannelName = "tt_bridge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startLockTask" -> {
                    try {
                        startLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_LOCK_TASK_FAILED", e.message, null)
                    }
                }
                "stopLockTask" -> {
                    try {
                        stopLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_LOCK_TASK_FAILED", e.message, null)
                    }
                }
                "isInLockTaskMode" -> {
                    result.success(isInLockTaskModeCompat())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "registerReceiver" -> {
                    registerWorkoutReceiver()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @SuppressLint("InlinedApi")
    private fun isInLockTaskModeCompat(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return try {
            // API 23+
            val state = am.lockTaskModeState
            state != ActivityManager.LOCK_TASK_MODE_NONE
        } catch (_: Throwable) {
            // Fallback (older APIs): if not available, assume not pinned
            false
        }
    }

    private var workoutReceiverRegistered = false

    private fun registerWorkoutReceiver() {
        if (workoutReceiverRegistered) return
        val filter = IntentFilter("com.example.timetracker.ACTION_LOG_WORKOUT")
        registerReceiver(WorkoutBroadcastReceiver(), filter)
        workoutReceiverRegistered = true
    }
}

