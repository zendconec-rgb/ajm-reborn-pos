/* AJM Reborn POS — multi-device client foundation
 * This module is intentionally NOT wired into transaction checkout yet.
 * It provides a durable IndexedDB outbox, per-browser device identity,
 * Supabase device registration, and idempotent outbox delivery.
 *
 * Load after supabase-js and after creating the authenticated Supabase client:
 *   window.AJM_MULTI_DEVICE.configure({ supabase: ajmSupabase, appVersion: '...' });
 *
 * Do not call enqueueOperation from checkout until the server-side transaction
 * processor, stock locking, conflict policy, and UI recovery flow are deployed.
 */
(function (global) {
  'use strict';

  const DB_NAME = 'ajm_reborn_multidevice';
  const DB_VERSION = 1;
  const DEVICE_STORE = 'device';
  const OUTBOX_STORE = 'outbox';
  const DEFAULT_BATCH_SIZE = 20;
  let supabase = null;
  let appVersion = null;
  let devicePromise = null;
  let flushPromise = null;

  function openDb() {
    return new Promise((resolve, reject) => {
      if (!global.indexedDB) return reject(new Error('IndexedDB tidak tersedia di browser ini.'));
      const request = global.indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(DEVICE_STORE)) {
          db.createObjectStore(DEVICE_STORE, { keyPath: 'key' });
        }
        if (!db.objectStoreNames.contains(OUTBOX_STORE)) {
          const store = db.createObjectStore(OUTBOX_STORE, { keyPath: 'operation_id' });
          store.createIndex('created_at', 'created_at', { unique: false });
          store.createIndex('status', 'status', { unique: false });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('Gagal membuka IndexedDB.'));
      request.onblocked = () => reject(new Error('Database lokal sedang digunakan tab lain. Tutup tab AJM lain lalu coba lagi.'));
    });
  }

  function requestResult(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('Operasi IndexedDB gagal.'));
    });
  }

  async function getDeviceKey() {
    if (devicePromise) return devicePromise;
    devicePromise = (async () => {
      const db = await openDb();
      try {
        const tx = db.transaction(DEVICE_STORE, 'readonly');
        const saved = await requestResult(tx.objectStore(DEVICE_STORE).get('primary'));
        if (saved && saved.device_key) return saved.device_key;
        const deviceKey = (global.crypto && global.crypto.randomUUID)
          ? global.crypto.randomUUID()
          : 'ajm-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
        const writeTx = db.transaction(DEVICE_STORE, 'readwrite');
        writeTx.objectStore(DEVICE_STORE).put({
          key: 'primary',
          device_key: deviceKey,
          device_name: (global.navigator && global.navigator.userAgent || 'AJM Device').slice(0, 110),
          created_at: new Date().toISOString()
        });
        await new Promise((resolve, reject) => {
          writeTx.oncomplete = resolve;
          writeTx.onerror = () => reject(writeTx.error || new Error('Gagal menyimpan identitas perangkat.'));
          writeTx.onabort = () => reject(writeTx.error || new Error('Penyimpanan identitas perangkat dibatalkan.'));
        });
        return deviceKey;
      } finally {
        db.close();
      }
    })().catch(err => {
      devicePromise = null;
      throw err;
    });
    return devicePromise;
  }

  async function configure(options) {
    if (!options || !options.supabase) throw new Error('Klien Supabase AJM belum diberikan.');
    supabase = options.supabase;
    appVersion = options.appVersion || null;
    return { deviceKey: await getDeviceKey() };
  }

  async function linkLocalIdentity(localUser) {
    if (!supabase) throw new Error('AJM multi-device belum dikonfigurasi.');
    if (!localUser || localUser.id == null || !localUser.username || !['Admin', 'Kasir'].includes(localUser.role)) {
      throw new Error('Identitas akun lokal AJM tidak lengkap.');
    }
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) throw sessionError;
    if (!sessionData || !sessionData.session) {
      throw new Error('Akun Supabase Auth belum terhubung. Hubungkan akun cloud masing-masing operator terlebih dahulu.');
    }
    const { data, error } = await supabase.rpc('ajm_link_local_identity', {
      p_local_user_id: String(localUser.id),
      p_local_username: String(localUser.username),
      p_local_role: String(localUser.role)
    });
    if (error) throw error;
    return Array.isArray(data) ? data[0] : data;
  }

  async function registerDevice() {
    if (!supabase) throw new Error('AJM multi-device belum dikonfigurasi.');
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) throw sessionError;
    if (!sessionData || !sessionData.session) throw new Error('Login Supabase diperlukan untuk mendaftarkan perangkat.');
    const deviceKey = await getDeviceKey();
    const { data, error } = await supabase.rpc('ajm_register_device', {
      p_device_key: deviceKey,
      p_device_name: ((global.navigator && global.navigator.userAgent) || 'AJM Device').slice(0, 110),
      p_app_version: appVersion
    });
    if (error) throw error;
    return { deviceKey, registration: Array.isArray(data) ? data[0] : data };
  }

  async function enqueueOperation(operationType, payload, options) {
    if (!operationType || typeof operationType !== 'string') throw new Error('Jenis operasi AJM wajib diisi.');
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('Payload operasi harus berupa objek.');
    const deviceKey = await getDeviceKey();
    const operationId = (global.crypto && global.crypto.randomUUID)
      ? global.crypto.randomUUID()
      : 'op-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
    const item = {
      operation_id: operationId,
      device_key: deviceKey,
      operation_type: operationType,
      payload: payload,
      client_created_at: (options && options.clientCreatedAt) || new Date().toISOString(),
      created_at: Date.now(),
      attempts: 0,
      status: 'pending',
      last_error: null
    };
    const db = await openDb();
    try {
      const tx = db.transaction(OUTBOX_STORE, 'readwrite');
      tx.objectStore(OUTBOX_STORE).add(item);
      await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error || new Error('Gagal menyimpan antrean offline.'));
        tx.onabort = () => reject(tx.error || new Error('Antrean offline dibatalkan.'));
      });
    } finally {
      db.close();
    }
    return { operationId, queued: true };
  }

  // Queue a completed AJM sale for the atomic server-side processor.
  // The transaction object retains the existing AJM invoice/items/customer/receipt fields.
  // Collision-resistant invoice suffix for devices that create sales while offline.
  // Keep the familiar INV-YYYYMMDD prefix while avoiding local transaction-count sequences.
  async function createOfflineInvoice(date) {
    const d = date instanceof Date ? date : new Date(date || Date.now());
    if (Number.isNaN(d.getTime())) throw new Error('Tanggal invoice tidak valid.');
    const deviceKey = await getDeviceKey();
    const devicePart = String(deviceKey).replace(/[^a-zA-Z0-9]/g, '').slice(0, 6).toUpperCase().padEnd(6, '0');
    const randomPart = (global.crypto && global.crypto.randomUUID)
      ? global.crypto.randomUUID().replace(/-/g, '').slice(0, 8).toUpperCase()
      : Math.random().toString(36).slice(2, 10).toUpperCase().padEnd(8, '0');
    const datePart = d.getFullYear()
      + String(d.getMonth() + 1).padStart(2, '0')
      + String(d.getDate()).padStart(2, '0');
    return 'INV-' + datePart + '-' + devicePart + '-' + randomPart;
  }

  async function queueSale(transaction) {
    if (!transaction || typeof transaction !== 'object' || Array.isArray(transaction)) {
      throw new Error('Data transaksi AJM tidak valid.');
    }
    if (!transaction.invoice || !Array.isArray(transaction.items) || transaction.items.length === 0) {
      throw new Error('Invoice dan item transaksi wajib tersedia.');
    }
    return enqueueOperation('sale.create', transaction);
  }

  // Queue debt collections with a stable payment ID generated before persistence.
  // The same queued operation is retried with the same operation_id and payment_id.
  async function queueDebtPayment(payment) {
    if (!payment || typeof payment !== 'object' || Array.isArray(payment)) {
      throw new Error('Data pembayaran piutang tidak valid.');
    }
    const invoice = String(payment.invoice || '').trim();
    const amount = Number(payment.amount);
    const method = String(payment.method || '').trim();
    const cashier = String(payment.cashier || '').trim();
    if (!invoice || !Number.isFinite(amount) || amount <= 0 || !method || !cashier) {
      throw new Error('Invoice, jumlah, metode, dan kasir wajib valid.');
    }
    const paymentId = String(payment.payment_id || (
      global.crypto && global.crypto.randomUUID ? global.crypto.randomUUID() :
      'dp-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2)
    ));
    return enqueueOperation('debt.payment', {
      invoice, payment_id: paymentId, amount, method, cashier,
      note: payment.note == null ? null : String(payment.note)
    });
  }

  async function queueWorkOrderCompletion(workOrder) {
    if (!workOrder || typeof workOrder !== 'object' || !workOrder.id) {
      throw new Error('ID work order wajib tersedia.');
    }
    return enqueueOperation('workorder.complete', {
      work_order_id: String(workOrder.id),
      completed_by: String(workOrder.completed_by || '')
    });
  }

  async function listOutbox() {
    const db = await openDb();
    try {
      const tx = db.transaction(OUTBOX_STORE, 'readonly');
      const all = await requestResult(tx.objectStore(OUTBOX_STORE).getAll());
      return all.sort((a, b) => a.created_at - b.created_at);
    } finally {
      db.close();
    }
  }

  async function updateOutbox(item) {
    const db = await openDb();
    try {
      const tx = db.transaction(OUTBOX_STORE, 'readwrite');
      tx.objectStore(OUTBOX_STORE).put(item);
      await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error || new Error('Gagal memperbarui antrean.'));
        tx.onabort = () => reject(tx.error || new Error('Pembaruan antrean dibatalkan.'));
      });
    } finally {
      db.close();
    }
  }

  async function removeOutbox(operationId) {
    const db = await openDb();
    try {
      const tx = db.transaction(OUTBOX_STORE, 'readwrite');
      tx.objectStore(OUTBOX_STORE).delete(operationId);
      await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error || new Error('Gagal menghapus operasi yang sudah diterima.'));
        tx.onabort = () => reject(tx.error || new Error('Penghapusan antrean dibatalkan.'));
      });
    } finally {
      db.close();
    }
  }

  async function flushQueue(options) {
    if (flushPromise) return flushPromise;
    if (!supabase) throw new Error('AJM multi-device belum dikonfigurasi.');
    if (global.navigator && global.navigator.onLine === false) return { sent: 0, pending: (await listOutbox()).length, offline: true };
    const batchSize = Math.max(1, Math.min(100, Number(options && options.batchSize) || DEFAULT_BATCH_SIZE));
    flushPromise = (async () => {
      await registerDevice();
      const queue = (await listOutbox()).filter(item => item.status === 'pending').slice(0, batchSize);
      let sent = 0;
      for (const item of queue) {
        try {
          let data;
          let error;
          if (item.operation_type === 'sale.create') {
            const response = await supabase.rpc('ajm_process_sale', {
              p_operation_id: item.operation_id,
              p_device_key: item.device_key,
              p_transaction: item.payload
            });
            data = response.data;
            error = response.error;
          } else if (item.operation_type === 'debt.payment') {
            const response = await supabase.rpc('ajm_apply_debt_payment', {
              p_operation_id: item.operation_id,
              p_device_key: item.device_key,
              p_invoice: item.payload.invoice,
              p_payment_id: item.payload.payment_id,
              p_amount: item.payload.amount,
              p_method: item.payload.method,
              p_cashier: item.payload.cashier,
              p_note: item.payload.note
            });
            data = response.data;
            error = response.error;
          } else if (item.operation_type === 'workorder.complete') {
            const response = await supabase.rpc('ajm_complete_work_order', {
              p_operation_id: item.operation_id,
              p_device_key: item.device_key,
              p_work_order_id: item.payload.work_order_id,
              p_completed_by: item.payload.completed_by
            });
            data = response.data;
            error = response.error;
          } else {
            const response = await supabase.rpc('ajm_submit_sync_operation', {
              p_operation_id: item.operation_id,
              p_device_key: item.device_key,
              p_operation_type: item.operation_type,
              p_payload: item.payload,
              p_client_created_at: item.client_created_at
            });
            data = response.data;
            error = response.error;
          }
          if (error) throw error;
          if (!data || !data.length) throw new Error('Server tidak mengonfirmasi operasi; item tetap disimpan di antrean.');
          if (['sale.create','debt.payment','workorder.complete'].includes(item.operation_type)) {
            const result = data[0];
            const successStatuses = item.operation_type === 'sale.create'
              ? ['posted','already_posted']
              : item.operation_type === 'debt.payment'
                ? ['applied','already_applied']
                : ['completed','already_completed'];
            if (successStatuses.includes(result.result_status)) {
              await removeOutbox(item.operation_id);
              sent++;
              continue;
            }
            item.status = ['stock_conflict','duplicate_invoice','amount_exceeds_debt','duplicate_payment_id'].includes(result.result_status)
              ? 'conflict' : 'blocked';
            item.last_error = result.result_message || result.result_status || 'Operasi belum diproses server.';
            item.last_attempt_at = new Date().toISOString();
            await updateOutbox(item);
            break;
          }
          // The generic RPC only persists an inbox row with status "pending";
          // it does NOT execute the business operation. Keep the durable item until
          // a dedicated server processor confirms completion. Never report inbox
          // acceptance as a completed sale/payment/work-order operation.
          const inboxResult = Array.isArray(data) ? data[0] : data;
          if (inboxResult && inboxResult.processing_status === 'processed') {
            await removeOutbox(item.operation_id);
            sent++;
          } else {
            item.status = 'submitted';
            item.last_error = 'Diterima server dan menunggu pemrosesan. Data tetap disimpan di perangkat.';
            item.server_received_at = inboxResult && inboxResult.received_at || new Date().toISOString();
            await updateOutbox(item);
          }
        } catch (error) {
          item.attempts = (item.attempts || 0) + 1;
          item.last_error = String(error && error.message || error).slice(0, 500);
          item.last_attempt_at = new Date().toISOString();
          // Permission/validation failures remain visible and are not silently discarded.
          if (error && ['42501', '22023', '28000'].includes(error.code)) item.status = 'blocked';
          await updateOutbox(item);
          break; // preserve order; retry later after the first failure is resolved
        }
      }
      const remaining = await listOutbox();
      return {
        sent,
        pending: remaining.filter(item => item.status === 'pending').length,
        submitted: remaining.filter(item => item.status === 'submitted').length,
        blocked: remaining.filter(item => item.status === 'blocked').length,
        conflicts: remaining.filter(item => item.status === 'conflict').length
      };
    })().finally(() => { flushPromise = null; });
    return flushPromise;
  }

  async function retryOperation(operationId) {
    const queue = await listOutbox();
    const item = queue.find(entry => entry.operation_id === operationId);
    if (!item) throw new Error('Operasi tidak ditemukan di antrean.');
    item.status = 'pending';
    item.last_error = null;
    await updateOutbox(item);
    return { operationId, status: 'pending' };
  }

  async function getStatus() {
    const queue = await listOutbox();
    return {
      deviceKey: await getDeviceKey(),
      queued: queue.length,
      blocked: queue.filter(item => item.status === 'blocked').length,
      conflicts: queue.filter(item => item.status === 'conflict').length,
      pending: queue.filter(item => item.status === 'pending').length,
      submitted: queue.filter(item => item.status === 'submitted').length,
      operations: queue.map(({ operation_id, operation_type, status, attempts, last_error, created_at, server_received_at }) => ({
        operation_id, operation_type, status, attempts, last_error, created_at, server_received_at
      }))
    };
  }

  global.AJM_MULTI_DEVICE = Object.freeze({
    configure,
    registerDevice,
    enqueueOperation,
    queueSale,
    queueDebtPayment,
    queueWorkOrderCompletion,
    createOfflineInvoice,
    retryOperation,
    flushQueue,
    getStatus,
    getDeviceKey
  });
})(window);
