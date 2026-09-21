package it.zerko.terraformingmars;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Unpacks the packaged nodejs-project (server bundle, client bundle, assets)
 * from the APK into the app's files directory, where Node can read it.
 *
 * The project ships as one zip asset because the Android asset merger
 * strips ".gz" from asset names, which would make the client's plain and
 * gzipped files collide. The copy is refreshed whenever the installed app
 * version changes; the db/ folder inside the project, where the server
 * keeps saved games, survives the refresh.
 */
final class ProjectInstaller {
  private static final String TAG = "TerraformingMars";
  private static final String PROJECT_ASSET = "nodejs-project.zip";
  private static final String PROJECT_FOLDER = "nodejs-project";
  private static final String DATABASE_FOLDER = "db";
  private static final String STAMP_FILE = ".installed-version";

  private ProjectInstaller() {
  }

  /** Makes sure the project on disk matches the one packaged in this build, and returns its folder. */
  static File install(Context context) throws IOException {
    File target = new File(context.getFilesDir(), PROJECT_FOLDER);
    String stamp = BuildConfig.VERSION_CODE + " " + BuildConfig.VERSION_NAME;
    File stampFile = new File(target, STAMP_FILE);
    if (stampFile.isFile() && stamp.equals(new String(Files.readAllBytes(stampFile.toPath()), StandardCharsets.UTF_8))) {
      return target;
    }
    Log.i(TAG, "Installing nodejs-project " + stamp + " into " + target);
    if (target.isDirectory()) {
      for (File child : listOrEmpty(target)) {
        if (!child.getName().equals(DATABASE_FOLDER)) {
          deleteRecursively(child);
        }
      }
    } else if (!target.mkdirs()) {
      throw new IOException("Cannot create " + target);
    }
    try (InputStream asset = context.getAssets().open(PROJECT_ASSET)) {
      unzip(asset, target);
    }
    try (OutputStream out = new FileOutputStream(stampFile)) {
      out.write(stamp.getBytes(StandardCharsets.UTF_8));
    }
    return target;
  }

  private static void unzip(InputStream in, File target) throws IOException {
    String root = target.getCanonicalPath() + File.separator;
    byte[] buffer = new byte[64 * 1024];
    try (ZipInputStream zip = new ZipInputStream(in)) {
      ZipEntry entry;
      while ((entry = zip.getNextEntry()) != null) {
        File file = new File(target, entry.getName());
        if (!file.getCanonicalPath().startsWith(root)) {
          throw new IOException("Zip entry escapes the project folder: " + entry.getName());
        }
        if (entry.isDirectory()) {
          if (!file.isDirectory() && !file.mkdirs()) {
            throw new IOException("Cannot create " + file);
          }
          continue;
        }
        File parent = file.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
          throw new IOException("Cannot create " + parent);
        }
        try (OutputStream out = new FileOutputStream(file)) {
          int read;
          while ((read = zip.read(buffer)) != -1) {
            out.write(buffer, 0, read);
          }
        }
        zip.closeEntry();
      }
    }
  }

  private static void deleteRecursively(File file) throws IOException {
    if (file.isDirectory()) {
      for (File child : listOrEmpty(file)) {
        deleteRecursively(child);
      }
    }
    if (!file.delete() && file.exists()) {
      throw new IOException("Cannot delete " + file);
    }
  }

  private static File[] listOrEmpty(File dir) {
    File[] children = dir.listFiles();
    return children == null ? new File[0] : children;
  }
}
