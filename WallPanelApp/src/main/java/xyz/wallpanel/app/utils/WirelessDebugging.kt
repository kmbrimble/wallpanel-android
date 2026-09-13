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
 * Android resets Wireless Debugging ("adb_wifi_enabled") to off on every reboot; there is
 * no OS setting to make it sticky. Community tools (KeepADB, adb-auto-enable) re-enable it
 * with WRITE_SECURE_SETTINGS, no root required -- same permission and mechanism as
 * [DuraSpeed]. Re-enabling only starts the listener; a device still has to be paired
 * before anything can connect to it.
 */
object WirelessDebugging {

    private const val TAG = "WallPanelWirelessDebug"

    /** Global setting for the Android 11+ Wireless Debugging toggle. */
    private const val SETTING = "adb_wifi_enabled"

    /**
     * Turn Wireless Debugging on if we hold WRITE_SECURE_SETTINGS and it's currently off.
     * Safe and silent when the permission is absent.
     *
     * Call on every process start, not just first run -- a reboot resets the toggle, not
     * just a fresh install.
     */
    fun enableIfPermitted(context: Context) {
        val held = context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED
        if (!held) {
            Log.i(TAG, "WRITE_SECURE_SETTINGS not held, skipping")
            return
        }
        try {
            val current = Settings.Global.getInt(context.contentResolver, SETTING, 0)
            if (current != 0) {
                Log.i(TAG, "$SETTING already 1")
                return
            }
            val ok = Settings.Global.putInt(context.contentResolver, SETTING, 1)
            Log.i(TAG, "$SETTING <- 1, write returned $ok")
        } catch (e: Exception) {
            // Grant can be revoked between the check and the write, and OEM builds vary.
            // Never let this stop the app starting.
            Log.w(TAG, "failed writing $SETTING", e)
        }
    }
}
