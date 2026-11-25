'use strict';

const { app, BrowserWindow, dialog, shell, session } = require('electron');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const APP_HOST = '127.0.0.1';
const SIGNER_HOST = 'http://127.0.0.1:18777';
let mainWindow = null;
let localServer = null;
let appOrigin = '';

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });
}

function startLocalAppServer() {
  return new Promise((resolve, reject) => {
    const htmlPath = path.join(app.getAppPath(), 'index.html');
    localServer = http.createServer((req, res) => {
      const route = (req.url || '').split('?')[0];
      if (req.method !== 'GET' || !['/', '/index.html', '/favicon.ico'].includes(route)) {
        res.writeHead(404, { 'Cache-Control': 'no-store' });
        return res.end('Not found');
      }
      if (route === '/favicon.ico') {
        res.writeHead(204);
        return res.end();
      }
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Referrer-Policy': 'strict-origin-when-cross-origin'
      });
      fs.createReadStream(htmlPath).on('error', () => {
        if (!res.headersSent) res.writeHead(500);
        res.end('AJM Reborn POS could not load its application file.');
      }).pipe(res);
    });
    localServer.once('error', reject);
    localServer.listen(0, APP_HOST, () => {
      const address = localServer.address();
      appOrigin = 'http://' + APP_HOST + ':' + address.port;
      resolve(appOrigin + '/');
    });
  });
}

function configurePermissions() {
  const ses = session.defaultSession;

  ses.setPermissionRequestHandler((webContents, permission, callback, details) => {
    const origin = details && details.requestingUrl ? details.requestingUrl : webContents.getURL();
    const isApp = origin.startsWith(appOrigin);
    const allowed = new Set(['bluetooth', 'bluetoothScanning', 'serial', 'usb', 'notifications']);
    if (isApp && allowed.has(permission)) return callback(true);
    if (isApp && permission === 'media') {
      const types = (details && details.mediaTypes) || [];
      return callback(types.includes('video'));
    }
    callback(false);
  });

  // Existing Windows printing uses the local QZ Tray signer on port 18777.
  // Web security remains enabled; only this local signer's CORS origin is extended.
  ses.webRequest.onHeadersReceived(
    { urls: [SIGNER_HOST + '/*'] },
    (details, callback) => {
      const headers = { ...(details.responseHeaders || {}) };
      for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === 'access-control-allow-origin') delete headers[key];
      }
      headers['Access-Control-Allow-Origin'] = [appOrigin];
      headers['Access-Control-Allow-Methods'] = ['GET, POST, OPTIONS'];
      headers['Access-Control-Allow-Headers'] = ['Content-Type'];
      headers['Vary'] = ['Origin'];
      callback({ responseHeaders: headers });
    }
  );
}

function attachDeviceChoosers(win) {
  const wc = win.webContents;

  wc.on('select-bluetooth-device', async (event, devices, callback) => {
    event.preventDefault();
    if (!devices || devices.length === 0) return callback('');
    const labels = devices.map(d => (d.deviceName || 'Perangkat Bluetooth') + (d.deviceId ? ' — ' + d.deviceId : ''));
    labels.push('Batal');
    const result = await dialog.showMessageBox(win, {
      type: 'question',
      title: 'Pilih Printer Bluetooth',
      message: 'Pilih perangkat Bluetooth yang ingin dihubungkan.',
      buttons: labels,
      cancelId: labels.length - 1,
      defaultId: 0,
      noLink: true
    });
    callback(result.response < devices.length ? devices[result.response].deviceId : '');
  });

  wc.on('select-usb-device', async (event, details, callback) => {
    event.preventDefault();
    const devices = (details && details.deviceList) || [];
    if (!devices.length) return callback('');
    const labels = devices.map(d => (d.productName || 'Perangkat USB') + ' — Vendor ' + (d.vendorId || '?') + ' / Produk ' + (d.productId || '?'));
    labels.push('Batal');
    const result = await dialog.showMessageBox(win, {
      type: 'question',
      title: 'Pilih Perangkat USB',
      message: 'Pilih perangkat USB yang akan digunakan.',
      buttons: labels,
      cancelId: labels.length - 1,
      defaultId: 0,
      noLink: true
    });
    callback(result.response < devices.length ? devices[result.response].deviceId : '');
  });

  wc.on('select-serial-port', async (event, portList, _webContents, callback) => {
    event.preventDefault();
    const ports = portList || [];
    if (!ports.length) return callback('');
    const labels = ports.map(p => (p.portName || 'Port serial') + (p.displayName ? ' — ' + p.displayName : ''));
    labels.push('Batal');
    const result = await dialog.showMessageBox(win, {
      type: 'question',
      title: 'Pilih Port Scanner',
      message: 'Pilih port serial untuk scanner barcode.',
      buttons: labels,
      cancelId: labels.length - 1,
      defaultId: 0,
      noLink: true
    });
    callback(result.response < ports.length ? ports[result.response].portId : '');
  });
}

async function createWindow() {
  const startUrl = await startLocalAppServer();
  configurePermissions();

  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1024,
    minHeight: 700,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#f1f5f9',
    title: 'AJM Reborn POS',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false
    }
  });

  attachDeviceChoosers(mainWindow);

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (!url.startsWith(appOrigin)) shell.openExternal(url);
    return { action: 'deny' };
  });

  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(appOrigin)) {
      event.preventDefault();
      if (/^https?:\\/\\//i.test(url)) shell.openExternal(url);
    }
  });

  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.on('closed', () => { mainWindow = null; });
  await mainWindow.loadURL(startUrl);
}

app.whenReady().then(createWindow).catch(err => {
  dialog.showErrorBox('AJM Reborn POS', 'Aplikasi gagal dibuka:\n' + err.message);
  app.quit();
});

app.on('window-all-closed', () => {
  if (localServer) localServer.close();
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

app.on('before-quit', () => {
  if (localServer) localServer.close();
});
