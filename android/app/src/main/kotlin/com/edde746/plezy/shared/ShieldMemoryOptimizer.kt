package com.edde746.plezy.shared

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor

/**
 * Intelligent background process memory trimmer and custom OTA helper tailored
 * for NVIDIA Shield TV (3GB RAM) and low-memory Android TV environments.
 *
 * Reclaims graphic buffers and cached userspace memory from dormant streaming apps
 * while strictly protecting user-specified essentials (Projectivy Launcher, Button Remapper,
 * Audiobookshelf) and core Android system services.
 */
object ShieldMemoryOptimizer {
  private const val TAG = "ShieldMemoryOptimizer"
  private const val CHANNEL_NAME = "com.plezy/shield_custom"

  // Core system and OS shells that must never be touched
  private val PROTECTED_PACKAGE_PREFIXES = setOf(
    "android",
    "com.android.systemui",
    "com.google.android.leanbacklauncher",
    "com.google.android.tvlauncher",
    "com.google.android.apps.tv.launcherx",
    "com.google.android.katniss",
    "com.google.android.tts",
    "com.google.android.inputmethod.latin",
    "com.nvidia.shield",
    "com.nvidia.tegra"
  )

  // Essential user utilities strictly whitelisted from background process termination
  private val PROTECTED_EXACT_PACKAGES = setOf(
    "com.spocky.projengmenu",          // Projectivy Launcher
    "com.spocky.projengmenu.launcher", // Projectivy Launcher variant
    "flar2.homebutton",                // Button Remapper
    "com.audiobookshelf.app",          // Audiobookshelf
    "org.courville.nova"               // Nova Video Player
  )

  // Common high-memory background streaming apps on Android TV
  private val KNOWN_BACKGROUND_STREAMING_TARGETS = listOf(
    "com.netflix.ninja",
    "com.amazon.amazonvideo.livingroom",
    "com.disney.disneyplus",
    "tv.twitch.android.app",
    "com.sling",
    "com.tubitv",
    "com.peacocktv.peacockandroid",
    "com.hbo.hbonow",
    "com.wbd.stream",
    "com.apple.atve.androidtv.appletv",
    "com.google.android.youtube.tv",
    "com.plexapp.android",
    "org.xbmc.kodi",
    "com.spotify.tv.android",
    "com.hulu.livingroomplus",
    "com.paramountplus.intl",
    "com.plutotv.android"
  )

  fun registerChannel(activity: Activity, flutterEngine: FlutterEngine, executor: Executor) {
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
      when (call.method) {
        "trimBackgroundMemory" -> {
          executor.execute {
            val report = trimBackgroundProcesses(activity)
            activity.runOnUiThread {
              result.success(report)
            }
          }
        }
        "canRequestPackageInstalls" -> {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            result.success(activity.packageManager.canRequestPackageInstalls())
          } else {
            result.success(true)
          }
        }
        "openUnknownAppSourcesSettings" -> {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
              val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:${activity.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
              }
              activity.startActivity(intent)
              result.success(true)
            } catch (e: Exception) {
              Log.e(TAG, "Failed to open unknown app sources settings", e)
              result.success(false)
            }
          } else {
            result.success(false)
          }
        }
        "installApk" -> {
          val filePath = call.argument<String>("filePath") ?: (call.arguments as? String)
          if (filePath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Missing filePath", null)
            return@setMethodCallHandler
          }
          try {
            val file = File(filePath)
            if (!file.exists()) {
              result.error("FILE_NOT_FOUND", "APK file does not exist: $filePath", null)
              return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !activity.packageManager.canRequestPackageInstalls()) {
              try {
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                  data = Uri.parse("package:${activity.packageName}")
                  addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(intent)
              } catch (e: Exception) {
                Log.w(TAG, "Failed to open unknown app sources settings", e)
              }
              result.error("PERMISSION_DENIED", "Install unknown apps permission required", null)
              return@setMethodCallHandler
            }
            val uri = FileProvider.getUriForFile(
              activity,
              "${activity.applicationContext.packageName}.fileprovider",
              file
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
              setDataAndType(uri, "application/vnd.android.package-archive")
              addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
              addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
              addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val resolvedList = activity.packageManager.queryIntentActivities(
              installIntent,
              PackageManager.MATCH_DEFAULT_ONLY
            )
            for (resolveInfo in resolvedList) {
              val pkg = resolveInfo.activityInfo.packageName
              activity.grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(installIntent)
            result.success(true)
          } catch (e: Exception) {
            Log.e(TAG, "Failed to launch APK installer", e)
            result.error("INSTALL_FAILED", e.message, null)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  fun trimBackgroundProcesses(context: Context): Map<String, Any> {
    val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
      ?: return mapOf("success" to false, "reason" to "no_activity_manager")

    val memInfoBefore = ActivityManager.MemoryInfo()
    activityManager.getMemoryInfo(memInfoBefore)
    val availMemBefore = memInfoBefore.availMem

    // Assemble dynamic protection set
    val fullProtectionSet = mutableSetOf<String>()
    fullProtectionSet.addAll(PROTECTED_EXACT_PACKAGES)
    fullProtectionSet.add(context.packageName) // Protect Plezy

    // Dynamically protect the current default Home launcher
    try {
      val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
      val resolveInfo = context.packageManager.resolveActivity(homeIntent, PackageManager.MATCH_DEFAULT_ONLY)
      resolveInfo?.activityInfo?.packageName?.let { fullProtectionSet.add(it) }
    } catch (t: Throwable) {
      Log.w(TAG, "Could not resolve default Home launcher for protection", t)
    }

    // Dynamically protect all enabled accessibility services (e.g. Button Remapper)
    try {
      val enabledServices = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
      ) ?: ""
      for (component in enabledServices.split(":")) {
        val pkg = component.split("/").firstOrNull()?.trim()
        if (!pkg.isNullOrEmpty()) {
          fullProtectionSet.add(pkg)
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "Could not resolve enabled accessibility services", t)
    }

    fun isProtected(pkg: String): Boolean {
      if (fullProtectionSet.contains(pkg)) return true
      return PROTECTED_PACKAGE_PREFIXES.any { prefix -> pkg == prefix || pkg.startsWith("$prefix.") }
    }

    val killedPackages = mutableListOf<String>()

    // 1. Explicitly kill known heavy streaming apps if inactive in background
    for (target in KNOWN_BACKGROUND_STREAMING_TARGETS) {
      if (!isProtected(target)) {
        try {
          activityManager.killBackgroundProcesses(target)
          killedPackages.add(target)
        } catch (t: Throwable) {
          Log.d(TAG, "Error trimming background package $target", t)
        }
      }
    }

    // 2. Scan running processes for background candidates
    try {
      val runningProcesses = activityManager.runningAppProcesses ?: emptyList()
      for (process in runningProcesses) {
        // Never touch foreground or visible processes
        if (process.importance > ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE) {
          val pkgList = process.pkgList ?: continue
          for (pkg in pkgList) {
            if (!isProtected(pkg) && !killedPackages.contains(pkg)) {
              try {
                activityManager.killBackgroundProcesses(pkg)
                killedPackages.add(pkg)
              } catch (t: Throwable) {
                Log.d(TAG, "Error trimming running background package $pkg", t)
              }
            }
          }
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "Could not inspect running app processes", t)
    }

    // 3. Request JVM GC to reclaim runtime allocations
    try {
      System.gc()
      Runtime.getRuntime().gc()
    } catch (_: Throwable) {}

    val memInfoAfter = ActivityManager.MemoryInfo()
    activityManager.getMemoryInfo(memInfoAfter)
    val availMemAfter = memInfoAfter.availMem
    val freedBytes = (availMemAfter - availMemBefore).coerceAtLeast(0L)

    Log.i(
      TAG,
      "ShieldMemoryOptimizer: trimmed ${killedPackages.size} packages. " +
        "Freed ~${freedBytes / (1024 * 1024)}MB. Avail RAM: ${availMemAfter / (1024 * 1024)}MB"
    )

    return mapOf(
      "success" to true,
      "freedBytes" to freedBytes,
      "availMem" to availMemAfter,
      "killedCount" to killedPackages.size,
      "shieldModel" to Build.MODEL
    )
  }
}
