/*
 * Copyright (c) 2022 Wallpanel
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package xyz.wallpanel.app.modules

import android.hardware.Camera
import com.google.android.gms.vision.CameraSource
import timber.log.Timber
import kotlin.math.abs

/**
 * Pins the sensor preview frame rate after a [CameraSource] has started.
 *
 * [CameraSource.Builder.setRequestedFps] only picks the *closest* supported range, which on this
 * hardware means a wide variable range (e.g. [5000,30000]) that the HAL floats up to its maximum in
 * good light -- requesting 5fps still delivered ~20fps measured. Choosing the range by its ceiling
 * and writing it back directly is what actually reduces frames delivered, and with them the CPU,
 * power and log cost of motion detection.
 *
 * ponytail: reflects into CameraSource's private Camera because GMS Vision exposes no way to set a
 * preview FPS range. Upgrade path is CameraX/Camera2, which is deliberately out of scope here.
 */
object CameraFpsPin {

    /**
     * Must be called after every successful [CameraSource.start], on the same thread -- a camera
     * that is released and reopened (screen off/on, screensaver mount, app restart) comes back at
     * the HAL default otherwise.
     */
    fun apply(cameraSource: CameraSource?, targetFps: Float) {
        if (cameraSource == null || targetFps <= 0) return
        try {
            val camera = extractCamera(cameraSource) ?: run {
                Timber.w("Could not reach the underlying Camera; preview FPS left at the HAL default")
                return
            }
            val parameters = camera.parameters
            val supported = parameters.supportedPreviewFpsRange
            if (supported.isNullOrEmpty()) return

            Timber.i("Supported preview FPS ranges: %s", supported.joinToString { "[${it[0]},${it[1]}]" })

            val best = chooseRange(supported, targetFps) ?: return
            parameters.setPreviewFpsRange(best[0], best[1])
            camera.parameters = parameters
            Timber.i("Pinned preview FPS range to [%d,%d] for requested %.1ffps", best[0], best[1], targetFps)
        } catch (e: Exception) {
            // A camera that runs too fast still works; one we've thrown out of does not.
            Timber.e(e, "Failed to pin preview FPS range")
        }
    }

    /**
     * Picks the supported range whose ceiling is closest to [targetFps], since the ceiling is what
     * the HAL actually delivers. The floor only breaks ties.
     */
    internal fun chooseRange(supported: List<IntArray>, targetFps: Float): IntArray? {
        val target = (targetFps * 1000).toInt()
        return supported.minByOrNull { 2 * abs(it[1] - target) + abs(it[0] - target) }
    }

    private fun extractCamera(cameraSource: CameraSource): Camera? {
        for (field in cameraSource.javaClass.declaredFields) {
            if (field.type == Camera::class.java) {
                field.isAccessible = true
                return field.get(cameraSource) as? Camera
            }
        }
        return null
    }
}
