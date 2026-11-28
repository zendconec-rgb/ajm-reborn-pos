# Pengujian Manajemen Perangkat AJM Reborn POS

## Status implementasi
- UI Admin berada di Pengaturan → Manajemen Perangkat.
- Identitas perangkat disimpan per browser/perangkat pada localStorage.
- Heartbeat dikirim setiap 60 detik ketika sesi Supabase Auth aktif.
- Status Online dihitung dari heartbeat dalam 2 menit terakhir.
- RPC server membatasi maksimal 3 perangkat aktif per akun Supabase Auth.
- Admin harus memiliki role server-side pada `app_metadata`; role Admin lokal saja tidak cukup.
- Pencabutan akses diproses pada heartbeat berikutnya (maksimal sekitar 60 detik jika perangkat online).

## Aktivasi database (belum dijalankan otomatis)
1. Buka Supabase project AJM Reborn POS → SQL Editor.
2. Jalankan seluruh isi `supabase/migrations/20261128_device_management.sql`.
3. Tetapkan klaim admin pada akun Supabase Auth tepercaya, sesuai komentar SQL pada migration.
4. Login ke aplikasi dengan akun Admin lokal dan akun cloud Supabase yang sama di setiap perangkat.
5. Buka Pengaturan → Manajemen Perangkat dan tekan Muat Ulang.

## Skenario uji wajib sebelum merge/deploy
1. Perangkat 1, 2, dan 3 login ke akun cloud yang sama; ketiganya muncul dalam daftar.
2. Perangkat yang mengirim heartbeat tampil Online; tutup aplikasi/browser dan tunggu lebih dari 2 menit untuk memastikan status Offline.
3. Coba login perangkat ke-4; server harus menolak registrasi baru dengan `AJM_DEVICE_LIMIT_REACHED`.
4. Admin menonaktifkan perangkat 2; setelah heartbeat berikutnya perangkat 2 harus keluar dan tidak dapat mendaftar ulang.
5. Admin mengaktifkan kembali perangkat 2; perangkat tersebut dapat login kembali selama kuota tersedia.
6. Akun non-admin mencoba memanggil RPC daftar/nonaktifkan; server harus menolak dengan `AJM_DEVICE_ADMIN_REQUIRED`.
7. Pastikan transaksi, produk, pelanggan, laporan, printer, dan sinkronisasi data lama tetap berfungsi.

## Catatan keamanan
- Aksi admin divalidasi oleh PostgreSQL RPC menggunakan `auth.uid()` dan `app_metadata`, bukan hanya tombol/UI di browser.
- Tabel registry tidak memberi akses langsung ke role anon/authenticated; akses melalui RPC.
- Identitas browser berbasis localStorage bukan attestation perangkat keras. Penghapusan data browser dapat menghasilkan ID baru; untuk lingkungan berisiko tinggi diperlukan autentikasi/perangkat native yang lebih kuat.
- Migrasi ini belum diterapkan ke database produksi. Uji di project/staging terlebih dahulu sebelum penerapan produksi.
