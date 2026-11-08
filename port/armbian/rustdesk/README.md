# RustDesk на Armbian: проверено, не доработано

Состояние на 03.10.2026: официальный RustDesk 1.4.9 (arm64 .deb) на Armbian работает, но
изображение — единицы кадров в секунду. Доработка, как для Android (`port/apps/rustdesk`),
отложена: аппаратный декодер здесь придерживает кадры (см. ниже).

## Официальный клиент

- Ставится штатным пакетом: `apt install ./rustdesk-1.4.9-aarch64.deb` (вместе со службой
  `rustdesk.service` — через неё можно подключиться и к самой приставке; если не нужно,
  `systemctl disable --now rustdesk`).
- **Декодирование программное в один поток.** RustDesk для Linux умеет аппаратные декодеры только
  CUDA (NVIDIA) и VAAPI (Intel/AMD), а V4L2 (meson-vdec) — нет: в журнале
  (`~/.local/share/logs/RustDesk/`) `ram_decode` содержит только `hwdevice: NONE`. Потоков
  декодера — половина свободной памяти в ГБ: `available memory: 0G, codec thread: 1`. Итог на
  2560×1080 H.265: ~1 ядро на декодирование, ~0,5 ядра на вывод, пара кадров в секунду.
- **Память.** RustDesk (4 процесса) + Xfce занимают почти всё из 785 МБ. Если открыть ещё и
  браузер (вход в аккаунт RustDesk через Thorium), zram и файл подкачки на карте заполняются,
  система почти встаёт (нагрузка ~22), а Wi-Fi отваливается (`WLC_DISASSOC failed -110` —
  драйвер не успевает ответить чипу). Закрытие браузера возвращает всё за минуту.
- **Публичные серверы RustDesk** требуют входа в аккаунт («Due to ongoing scamming and botnet
  abuse, this public server currently requires users to log in before connecting»). В домашней
  сети без аккаунта: на ПК включить «Разрешить прямой IP-доступ» (порт 21118), на приставке
  вместо ID ввести IP компьютера.

## Аппаратный декодер meson-vdec в режиме удалённого стола

Проверено пробниками из этой папки (собираются и работают на приставке; нужны
`libavcodec-dev libavformat-dev libavutil-dev gcc`), поток x264 без B-кадров, 2560×1080:

| | |
|---|---|
| скорость | ~86 кадр/с 2560×1080, ~73 кадр/с 1920×1080, CPU < 0,25 ядра |
| `v4ltest` (ffmpeg `h264_v4l2m2m`) | кадр выходит, когда поданы ещё 4 (ffmpeg не даёт буферов меньше 6/20) |
| `v4lraw` (V4L2 напрямую) | кадр выходит, когда поданы ещё **3** (~100 мс при 30 кадр/с); последние 3 кадра потока не выходят без EOS |
| AUD или end-of-sequence в конце кадра | не помогает (AUD — хуже) |
| `meson-vdec-h264-dpb-param.patch`, `h264_dpb_field=0` | **2** кадра (~68 мс) |

Третий байт `AV_SCRATCH_0`, который драйвер пишет как `max_refs - 1`, прошивка использует как
задержку вывода; 0 — минимум, остальное задерживает сама прошивка (`gxl_h264.bin`).
Для удалённого стола это значит +70 мс и **застревание последних двух кадров на неподвижном
экране** (напечатанная буква появится, когда экран изменится ещё дважды). Возможный обход — после
паузы сливать декодер (`V4L2_DEC_CMD_STOP`) и просить у ПК ключевой кадр — не проверялся.

Сборка модуля (на приставке, ядро ophub 6.18.51 собрано GCC 15): исходники
`drivers/staging/media/meson/vdec` из `unifreq/linux-6.18.y` (тег `v6.18.51`) + патч,
`obj-m += meson-vdec.o` в Makefile, Arm GNU Toolchain 15.2 aarch64-hosted в `/opt/armgcc`,
`modpost` пересобрать местным gcc (`gcc -I…/scripts/include -I. -o modpost modpost.c
file2alias.c sumversion.c symsearch.c`, родной сохранён как `modpost.orig`), затем
`make -C /lib/modules/$(uname -r)/build M=$PWD CC=/opt/armgcc/bin/aarch64-none-linux-gnu-gcc modules`.
Проверка без установки: `rmmod meson_vdec; insmod meson-vdec.ko`; параметр
`/sys/module/meson_vdec/parameters/h264_dpb_field` (-1 — как в оригинале).

## Если продолжать

1. Проверить обход застревания кадров (слив + ключевой кадр).
2. Собрать `librustdesk.so` для aarch64 Linux (кросс-сборка с GTK и vcpkg-ffmpeg с
   `--enable-v4l2-m2m`; на приставке собирать нельзя — мало памяти) и подложить в официальный
   пакет (`/usr/share/rustdesk/lib/`): декодер `h264_v4l2m2m` в hwcodec, снять ограничение
   потоков `codec_thread_num`.
3. Измерить вывод: Flutter на Linux показывает кадр через RGBA-текстуру (копия ~11 МБ на кадр
   через Mali-450 / lima).
