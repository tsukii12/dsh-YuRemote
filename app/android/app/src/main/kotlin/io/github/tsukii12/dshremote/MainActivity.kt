package io.github.tsukii12.dshremote

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.tsukii12.dshremote.files.FilesPlugin
import io.github.tsukii12.dshremote.media.MediaPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(FilesPlugin())
        flutterEngine.plugins.add(MediaPlugin())
    }
}
