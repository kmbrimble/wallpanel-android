/*
 * Copyright (c) 2022 WallPanel
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed 
 * under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
 * See the License for the specific language governing permissions and 
 * limitations under the License.
 */

package xyz.wallpanel.app.utils

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log

/**
 * MediaTek DuraSpeed suppresses service starts for apps on its list. On affected devices
 * that includes the SandboxedProcessService the WebView needs for a renderer: the bind is
 * accepted by AMS and then never acted on, so the app runs with a permanently blank page.
 *
 * Reproduced on this project's panel after an `adb shell am force-stop` of the app. A
 * force-stop issued from Settings by the user did NOT reproduce it (5/5 clean), so this
 * mostly bites developers. See README "MediaTek DuraSpeed".
 */
object DuraSpeed {

    private const val TAG = "WallPanelDuraSpeed"

    /** Global setting DuraSpeed reads. Not a public constant; the name is the API. */
    const val SETTING = "setting.duraspeed.enabled"

    /** Vendor property set on devices that ship DuraSpeed at all. */
    private const val SUPPORT_PROP = "persist.vendor.duraspeed.support"

    /**
     * True when this device ships DuraSpeed. Read via `getprop` rather than
     * SystemProperties reflection, which is on the hidden-API greylist.
     */
    fun isSupportedDevice(): Boolean = readProp(SUPPORT_PROP) == "1"

    /**
     * Turn DuraSpeed off if we hold WRITE_SECURE_SETTINGS (granted over adb; most
     * installs will not have it). Safe and silent when the permission is absent.
     *
     * Call on every process start, not just first run — a reboot re-enables DuraSpeed.
     */
    fun disableIfPermitted(context: Context) {
        val held = context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "WRITE_SECURE_SETTINGS held=$held")
        if (!held) return
        try {
            val ok = Settings.Global.putString(context.contentResolver, SETTING, "0")
            Log.i(TAG, "$SETTING <- 0, write returned $ok")
        } catch (e: Exception) {
            // Grant can be revoked between the check and the write, and OEM builds vary.
            // Never let this stop the app starting.
            Log.w(TAG, "failed writing $SETTING", e)
        }
    }

    private fun readProp(name: String): String? = try {
        Runtime.getRuntime().exec(arrayOf("getprop", name))
            .inputStream.bufferedReader().use { it.readLine() }?.trim()
    } catch (e: Exception) {
        Log.w(TAG, "failed reading $name", e)
        null
    }
}
