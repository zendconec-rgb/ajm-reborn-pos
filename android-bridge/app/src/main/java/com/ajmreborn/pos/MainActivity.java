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
import android.webkit.PermissionRequest;
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
    private static final int REQUEST_CAMERA_PERMISSION = 4102;
    private static final UUID SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");
    private static final String APP_URL = "https://zendconec-rgb.github.io/ajm-reborn-pos/";
    private WebView webView;
    private PermissionRequest pendingCameraRequest;
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            getWindow().setStatusBarContrastEnforced(false);
            getWindow().setNavigationBarContrastEnforced(false);
        }
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
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
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest request) {
                main.post(() -> {
                    boolean videoRequested = false;
                    for (String resource : request.getResources()) {
                        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)) videoRequested = true;
                    }
                    if (!videoRequested) { request.deny(); return; }
                    if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        request.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                    } else {
                        if (pendingCameraRequest != null) pendingCameraRequest.deny();
                        pendingCameraRequest = request;
                        requestPermissions(new String[]{Manifest.permission.CAMERA}, REQUEST_CAMERA_PERMISSION);
                    }
                });
            }
            @Override public void onPermissionRequestCanceled(PermissionRequest request) {
                if (pendingCameraRequest == request) pendingCameraRequest = null;
            }
        });
        webView.setWebViewClient(new WebViewClient() { @Override public void onPageFinished(android.webkit.WebView view, String url) { super.onPageFinished(view, url); view.evaluateJavascript("(function(){if(window.__ajmNativeInstalled)return;window.__ajmNativeInstalled=true;function status(t,m){var e=document.getElementById('printer-device-name-label');if(e)e.textContent=m||t;}window.ajmNativePrinterStatus=function(raw){try{var o=typeof raw==='string'?JSON.parse(raw):raw;status(o.status,o.message);if(o.status==='connected'&&typeof showToast==='function')showToast('Printer Bluetooth terhubung: '+o.message);else if(o.status==='error'&&typeof showToast==='function')showToast(o.message);}catch(e){}};var oldPrint=window.sendRawEscPosViaRawBT;window.sendRawEscPosViaRawBT=function(trx){try{if(!window.AJMNativePrinter||AJMNativePrinter.isAvailable()!=='true')return oldPrint?oldPrint(trx):false;var p=buildEscPosReceiptBytes(trx),n=Math.max(1,Number(settings.printerCopies)||1),a=new Uint8Array(p.length*n);for(var c=0;c<n;c++)a.set(p,c*p.length);var b='',step=0x8000;for(var i=0;i<a.length;i+=step)b+=String.fromCharCode.apply(null,a.subarray(i,Math.min(i+step,a.length)));var r=AJMNativePrinter.sendBase64(btoa(b));if(r==='OK'){if(typeof showToast==='function')showToast('Struk dikirim langsung ke printer Bluetooth.');return true;}if(typeof showToast==='function')showToast(r.replace(/^ERROR:/,''));return false;}catch(e){if(typeof showToast==='function')showToast('Cetak Bluetooth gagal: '+e.message);return false;}};window.connectBluetoothPrinter=function(){try{if(!window.AJMNativePrinter||AJMNativePrinter.isAvailable()!=='true'){if(typeof showToast==='function')showToast('Bridge Bluetooth native tidak tersedia.');return;}var ds=JSON.parse(AJMNativePrinter.getBondedDevices()||'[]');if(!ds.length){if(typeof showToast==='function')showToast('Pasangkan RPP210A terlebih dahulu di pengaturan Bluetooth Android, PIN 0000 bila diminta.');return;}var menu=ds.map(function(d,i){return (i+1)+'. '+d.name+' ('+d.address+')';}).join('\\\\n');var pick=prompt('Pilih printer Bluetooth yang sudah dipasangkan:\\\\n'+menu,'1');var ix=parseInt(pick,10)-1;if(!Number.isFinite(ix)||ix<0||ix>=ds.length)return;var r=AJMNativePrinter.connectBluetooth(ds[ix].address);if(typeof showToast==='function')showToast(r==='CONNECTING'?'Menghubungkan ke '+ds[ix].name+'…':r);}catch(e){if(typeof showToast==='function')showToast('Gagal memilih printer: '+e.message);}};window.disconnectHardwarePrinter=function(){if(window.AJMNativePrinter)AJMNativePrinter.disconnect();};})();", null); } });
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
        if (requestCode == REQUEST_CAMERA_PERMISSION) {
            PermissionRequest request = pendingCameraRequest;
            pendingCameraRequest = null;
            if (request != null) {
                if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    request.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                } else {
                    request.deny();
                    // Web app displays the permission state; avoid stale native toast after a later successful grant.
                }
            }
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
                    // No discovery is started by this app. Avoid cancelDiscovery(),
                    // which requires BLUETOOTH_SCAN on Android 12+ and is unnecessary
                    // when connecting to an already paired RPP210A device.
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
