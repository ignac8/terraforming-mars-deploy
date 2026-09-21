package it.zerko.terraformingmars;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.TextView;

import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.ServerSocket;
import java.net.URL;

/**
 * A full-screen WebView on the game server that NodeRuntime runs inside this
 * process. The last page is remembered so that reopening the app lands back
 * in the game that was being played.
 */
public class MainActivity extends Activity {
  private static final String TAG = "TerraformingMars";
  private static final String PREFERENCES = "terraforming-mars";
  private static final String LAST_PATH = "lastPath";
  private static final long SERVER_TIMEOUT_MS = 90_000;

  /** The port the server listens on, chosen once per process. */
  private static int port = 0;

  private WebView webView;
  private View loading;
  private TextView status;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    setContentView(R.layout.activity_main);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

    webView = findViewById(R.id.webview);
    loading = findViewById(R.id.loading);
    status = findViewById(R.id.status);
    configure(webView);

    new Thread(this::startServerAndOpen, "server-boot").start();
  }

  private void configure(WebView view) {
    WebSettings settings = view.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    // The game lays itself out for a 1260px-wide desktop viewport; scale it
    // to the screen and let the player pinch-zoom, as a phone browser would.
    settings.setUseWideViewPort(true);
    settings.setLoadWithOverviewMode(true);
    settings.setSupportZoom(true);
    settings.setBuiltInZoomControls(true);
    settings.setDisplayZoomControls(false);
    view.setWebViewClient(new WebViewClient() {
      @Override
      public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
        Uri uri = request.getUrl();
        if (isLocalServer(uri)) {
          return false;
        }
        // Links out of the game (rules, GitHub, Discord) go to the system browser.
        try {
          startActivity(new Intent(Intent.ACTION_VIEW, uri));
        } catch (RuntimeException e) {
          Log.w(TAG, "No app can open " + uri, e);
        }
        return true;
      }

      @Override
      public void onPageFinished(WebView view, String url) {
        Uri uri = Uri.parse(url);
        if (isLocalServer(uri)) {
          String path = uri.getPath() + (uri.getQuery() == null ? "" : "?" + uri.getQuery());
          preferences().edit().putString(LAST_PATH, path).apply();
        }
      }
    });
  }

  private static boolean isLocalServer(Uri uri) {
    return "http".equals(uri.getScheme()) && "127.0.0.1".equals(uri.getHost()) && uri.getPort() == port;
  }

  private void startServerAndOpen() {
    try {
      synchronized (MainActivity.class) {
        if (port == 0) {
          port = pickFreePort();
        }
      }
      NodeRuntime.start(ProjectInstaller.install(this), port, getCacheDir());
      waitForServer();
    } catch (IOException | InterruptedException e) {
      Log.e(TAG, "The game server did not start", e);
      runOnUiThread(() -> status.setText(getString(R.string.server_failed, e.getMessage())));
      return;
    }
    String path = preferences().getString(LAST_PATH, "/");
    runOnUiThread(() -> {
      loading.setVisibility(View.GONE);
      webView.setVisibility(View.VISIBLE);
      webView.loadUrl(serverUrl(path));
    });
  }

  private static int pickFreePort() throws IOException {
    try (ServerSocket socket = new ServerSocket(0)) {
      socket.setReuseAddress(true);
      return socket.getLocalPort();
    }
  }

  private void waitForServer() throws IOException, InterruptedException {
    long deadline = System.currentTimeMillis() + SERVER_TIMEOUT_MS;
    IOException last = null;
    while (System.currentTimeMillis() < deadline) {
      try {
        HttpURLConnection connection = (HttpURLConnection) new URL(serverUrl("/")).openConnection();
        connection.setConnectTimeout(1000);
        connection.setReadTimeout(2000);
        int code = connection.getResponseCode();
        connection.disconnect();
        if (code == 200) {
          return;
        }
      } catch (IOException e) {
        last = e;
      }
      Thread.sleep(250);
    }
    throw new IOException("no answer on port " + port + " after " + (SERVER_TIMEOUT_MS / 1000) + "s", last);
  }

  private static String serverUrl(String path) {
    return "http://127.0.0.1:" + port + path;
  }

  private SharedPreferences preferences() {
    return getSharedPreferences(PREFERENCES, MODE_PRIVATE);
  }

  @Override
  public boolean onKeyDown(int keyCode, KeyEvent event) {
    if (keyCode == KeyEvent.KEYCODE_BACK && webView.getVisibility() == View.VISIBLE && webView.canGoBack()) {
      webView.goBack();
      return true;
    }
    return super.onKeyDown(keyCode, event);
  }
}
