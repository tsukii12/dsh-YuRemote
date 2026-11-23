package io.github.tsukii12.dshremote

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.tsukii12.dshremote.files.FilesPlugin
import io.github.tsukii12.dshremote.media.MediaPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(FilesPlugin())
        flutterEngine.plugins.add(MediaPlugin())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tsukii12.dshremote/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstallPackages" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                    )
                    "openInstallSettings" -> try {
                        val action = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES else Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                        startActivity(Intent(action, Uri.parse("package:$packageName")))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("settings_unavailable", error.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
