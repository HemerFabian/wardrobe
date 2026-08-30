package app.wardrobe.viewer

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    companion object {
        private const val WORKSPACE_EXPORT_CHANNEL =
            "app.wardrobe.viewer/workspace_export"
        private const val EXPORT_WORKSPACE_REQUEST_CODE = 4137
    }

    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportSourcePath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WORKSPACE_EXPORT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveWorkspaceZip" -> handleSaveWorkspaceZip(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleSaveWorkspaceZip(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingExportResult != null) {
            result.error(
                "export_in_progress",
                "Another workspace export is already waiting for a destination.",
                null,
            )
            return
        }

        val sourcePath =
            call.argument<String>("sourcePath")?.trim().orEmpty().takeIf { it.isNotEmpty() }
        if (sourcePath == null) {
            result.error("missing_source_path", "Missing workspace ZIP source path.", null)
            return
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            result.error(
                "missing_source_file",
                "Workspace ZIP does not exist: $sourcePath",
                null,
            )
            return
        }

        val fileName =
            call.argument<String>("fileName")?.trim().orEmpty().takeIf { it.isNotEmpty() }
                ?: "wardrobe_workspace.zip"

        pendingExportResult = result
        pendingExportSourcePath = sourcePath

        val intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, fileName)
            }

        try {
            startActivityForResult(intent, EXPORT_WORKSPACE_REQUEST_CODE)
        } catch (error: Exception) {
            pendingExportResult = null
            pendingExportSourcePath = null
            result.error(
                "picker_launch_failed",
                error.message ?: "Failed to open the export destination picker.",
                null,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_WORKSPACE_REQUEST_CODE) {
            return
        }

        val pendingResult = pendingExportResult
        val sourcePath = pendingExportSourcePath
        pendingExportResult = null
        pendingExportSourcePath = null

        if (pendingResult == null || sourcePath == null) {
            return
        }

        if (resultCode != Activity.RESULT_OK) {
            pendingResult.success(null)
            return
        }

        val targetUri = data?.data
        if (targetUri == null) {
            pendingResult.error(
                "no_target_uri",
                "No export destination was returned by the system picker.",
                null,
            )
            return
        }

        try {
            copyFileToUri(File(sourcePath), targetUri.toString())
            pendingResult.success(targetUri.toString())
        } catch (error: Exception) {
            pendingResult.error(
                "export_failed",
                error.message ?: "Failed to export workspace ZIP.",
                null,
            )
        }
    }

    private fun copyFileToUri(sourceFile: File, targetUri: String) {
        val uri = android.net.Uri.parse(targetUri)
        sourceFile.inputStream().use { input ->
            val output =
                contentResolver.openOutputStream(uri, "w")
                    ?: throw IOException("Could not open selected export destination.")
            output.use { stream ->
                input.copyTo(stream)
                stream.flush()
            }
        }
    }
}
