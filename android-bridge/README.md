# AJM Reborn POS Android

Aplikasi Android pendamping untuk versi browser AJM Reborn POS.

## Integrasi
- Memuat aplikasi web produksi dari https://zendconec-rgb.github.io/ajm-reborn-pos/
- Tidak menyalin atau mengubah `index.html`; versi browser tetap terpisah.
- Menyediakan JavaScript bridge `AJMNativePrinter` untuk Bluetooth Classic SPP.
- Mengirim data struk ESC/POS yang dibangun oleh aplikasi web langsung ke printer melalui Bluetooth.
- Target printer awal: RPP210A / PRJ-58D, thermal 58 mm, ESC/POS.

## Cara memakai printer
1. Aktifkan Bluetooth Android.
2. Pasangkan RPP210A dari pengaturan Bluetooth Android (PIN perangkat: 0000 jika diminta).
3. Buka AJM Reborn POS Android.
4. Masuk Pengaturan > Printer Thermal > Bluetooth / Native SPP.
5. Pilih RPP210A, tekan Hubungkan, lalu cetak struk tes.

Catatan: Bluetooth Classic SPP memerlukan perangkat sudah berstatus paired/bonded di Android. Aplikasi meminta izin Nearby devices pada Android 12+.

## Build
GitHub Actions workflow `.github/workflows/build-android-apk.yml` membangun APK debug saat folder `android-bridge/` berubah. APK diunggah sebagai artifact bernama `AJM-Reborn-POS-Android-debug`.

APK debug belum ditandatangani untuk distribusi Play Store. Uji cetak fisik tetap diperlukan pada printer target.
