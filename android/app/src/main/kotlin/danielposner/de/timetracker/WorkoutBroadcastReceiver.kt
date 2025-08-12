package danielposner.de.timetracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONArray

class WorkoutBroadcastReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    val payload = intent.getStringExtra("payload") ?: return

    // In die von Flutter genutzten SharedPreferences schreiben:
    val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    val key = "flutter.tt_bridge_pending"

    val existingJson = prefs.getString(key, null)
    val list = if (existingJson.isNullOrEmpty()) mutableListOf<String>() else JSONArray(existingJson).let { arr ->
      val l = mutableListOf<String>()
      for (i in 0 until arr.length()) l.add(arr.getString(i))
      l
    }

    if (!list.contains(payload)) {
      list.add(payload)
      val newJson = JSONArray(list).toString()
      prefs.edit().putString(key, newJson).apply()
    }
  }
}



