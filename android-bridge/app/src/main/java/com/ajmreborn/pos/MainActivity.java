package com.ajmreborn.pos;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.graphics.Color;
import android.view.View;
import android.widget.FrameLayout;
import android.view.WindowManager;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.OutputStream;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {
    private static final int REQUEST_BT_PERMISSION = 4101;
    private static final UUID SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");
    private static final String APP_URL = "https://zendconec-rgb.github.io/ajm-reborn-pos/";
    private WebView webView;
    private BluetoothAdapter bluetoothAdapter;
    private BluetoothSocket socket;
    private OutputStream outputStream;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Object writeLock = new Object();

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Keep opaque system bars and readable white status/navigation icons.
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS
                | WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        getWindow().setStatusBarColor(Color.rgb(23, 37, 84));
        getWindow().setNavigationBarColor(Color.rgb(17, 24, 39));
        getWindow().getDecorView().setSystemUiVisibility(0);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            getWindow().setDecorFitsSystemWindows(true);
        }
        bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(243, 246, 251));
        webView = new WebView(this);
        root.addView(webView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        // Android lays content below the status bar and above navigation bar.
        setContentView(root);
        WebSettings ws = webView.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setDatabaseEnabled(true);
        ws.setAllowFileAccess(false);
        ws.setAllowContentAccess(false);
        ws.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        webView.setWebChromeClient(new WebChromeClient());
        webView.setWebViewClient(new WebViewClient());
        webView.addJavascriptInterface(new PrinterBridge(), "AJMNativePrinter");
        webView.loadUrl(APP_URL);
        requestBluetoothPermissionIfNeeded();
    }

    private void requestBluetoothPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT}, REQUEST_BT_PERMISSION);
        }
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_BT_PERMISSION && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            toast("Izin Bluetooth diberikan. Silakan muat ulang AJM jika daftar printer belum muncul.");
        }
    }

    private boolean hasConnectPermission() {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED;
    }

    private void jsStatus(String status, String message) {
        try {
            JSONObject obj = new JSONObject();
            obj.put("status", status);
            obj.put("message", message == null ? "" : message);
            String json = obj.toString();
            main.post(() -> webView.evaluateJavascript("window.ajmNativePrinterStatus && window.ajmNativePrinterStatus(" + JSONObject.quote(json) + ");", null));
        } catch (Exception ignored) { }
    }

    private void toast(String message) { main.post(() -> Toast.makeText(this, message, Toast.LENGTH_LONG).show()); }

    private class PrinterBridge {
        @JavascriptInterface public String isAvailable() { return bluetoothAdapter == null ? "false" : "true"; }
        @JavascriptInterface public String isConnected() {
            synchronized (writeLock) { return socket != null && socket.isConnected() && outputStream != null ? "true" : "false"; }
        }
        @JavascriptInterface public String getBondedDevices() {
            if (bluetoothAdapter == null || !hasConnectPermission()) return "[]";
            try {
                JSONArray arr = new JSONArray();
                Set<BluetoothDevice> devices = bluetoothAdapter.getBondedDevices();
                for (BluetoothDevice d : devices) {
                    JSONObject item = new JSONObject();
                    item.put("name", d.getName() == null ? "Bluetooth Printer" : d.getName());
                    item.put("address", d.getAddress());
                    arr.put(item);
                }
                return arr.toString();
            } catch (Exception e) { return "[]"; }
        }
        @JavascriptInterface public String connectBluetooth(String address) {
            if (bluetoothAdapter == null) return "ERROR:Bluetooth tidak tersedia";
            if (!hasConnectPermission()) { main.post(() -> requestBluetoothPermissionIfNeeded()); return "ERROR:Izin Bluetooth belum diberikan"; }
            if (address == null || !address.matches("(?i)[0-9A-F]{2}(:[0-9A-F]{2}){5}")) return "ERROR:Alamat printer tidak valid";
            io.execute(() -> {
                disconnectInternal();
                BluetoothDevice device;
                try {
                    bluetoothAdapter.cancelDiscovery();
                    device = bluetoothAdapter.getRemoteDevice(address);
                    Exception lastError = null;
                    BluetoothSocket connected = null;
                    // Try standard secure SPP first, then insecure SPP for printer modules
                    // that expose the serial profile without secure RFCOMM pairing.
                    for (int mode = 0; mode < 2 && connected == null; mode++) {
                        BluetoothSocket candidate = null;
                        try {
                            candidate = mode == 0
                                    ? device.createRfcommSocketToServiceRecord(SPP_UUID)
                                    : device.createInsecureRfcommSocketToServiceRecord(SPP_UUID);
                            final BluetoothSocket timeoutSocket = candidate;
                            Runnable timeout = () -> { try { timeoutSocket.close(); } catch (Exception ignored) { } };
                            main.postDelayed(timeout, 12000);
                            try { candidate.connect(); }
                            finally { main.removeCallbacks(timeout); }
                            connected = candidate;
                        } catch (Exception e) {
                            lastError = e;
                            try { if (candidate != null) candidate.close(); } catch (Exception ignored) { }
                        }
                    }
                    if (connected == null) throw lastError == null ? new Exception("Printer tidak merespons") : lastError;
                    synchronized (writeLock) {
                        socket = connected;
                        outputStream = connected.getOutputStream();
                    }
                    jsStatus("connected", device.getName() == null ? address : device.getName());
                } catch (Exception e) {
                    disconnectInternal();
                    String detail = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                    jsStatus("error", "Koneksi SPP gagal. Pastikan printer menyala, sudah dipasangkan, dan tidak sedang terhubung ke HP lain. Detail: " + detail);
                }
            });
            return "CONNECTING";
        }
        @JavascriptInterface public String sendBase64(String base64) {
            try {
                byte[] bytes = Base64.decode(base64, Base64.DEFAULT);
                synchronized (writeLock) {
                    if (socket == null || !socket.isConnected() || outputStream == null) return "ERROR:Printer belum terhubung";
                    outputStream.write(bytes);
                    outputStream.flush();
                }
                return "OK";
            } catch (Exception e) { return "ERROR:" + (e.getMessage() == null ? "Gagal mengirim data" : e.getMessage()); }
        }
        @JavascriptInterface public String disconnect() { disconnectInternal(); jsStatus("disconnected", "Printer diputus"); return "OK"; }
    }

    private void disconnectInternal() {
        synchronized (writeLock) {
            try { if (outputStream != null) outputStream.close(); } catch (Exception ignored) { }
            try { if (socket != null) socket.close(); } catch (Exception ignored) { }
            outputStream = null;
            socket = null;
        }
    }

    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }

    @Override protected void onDestroy() {
        disconnectInternal();
        io.shutdownNow();
        if (webView != null) webView.destroy();
        super.onDestroy();
    }
}
