# Armbian на Rombica SmartBox A2 (S905L2) с microSD

Проверено 30.09–02.10.2026: Armbian 26.11 (Debian 12 bookworm, ядро 6.18.51) из проекта
[ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian), сборка
`amlogic_s905l2`, плюс наши правки. Android на eMMC не затрагивается: без карты приставка грузит
Android, с картой — показывает меню «Android | Armbian» (с загрузчиком порта v1.2).

## Готовые образы

Собранные образы — в [Releases](https://github.com/dolbaras/rombica-smartbox-a2-roms/releases) репозитория rombica-smartbox-a2-roms (`.img.xz`;
`write_image.sh` пишет их без распаковки). Там пока образы v1.2: образ v1.3 из этой папки (драйвер индикатора,
NetworkManager вместо `wifi-watchdog`, MPLL от загрузчика вместо `s905l2-mpll-load`, родной режим
монитора) на приставке ещё не проверен — см. «Не сделано». `build_image.sh` собирает из образа ophub два образа с уже применёнными
правками этой папки:

| | |
|---|---|
| `…_server.img` (3,7 ГБ) | консоль: DTB, меню загрузки, Wi-Fi, звук, пульт, индикатор, zram |
| `…_desktop.img` (6,9 ГБ) | плюс Xfce + LightDM, Thorium с enhanced-h264ify и закладкой «▶ HW», `yt-play`, режим мыши пульта, окно «Индикатор», экран в родном режиме монитора/ТВ, файл подкачки 1 ГБ |

```bash
sudo env E2FSPROGS=<e2fsprogs 1.47, если в системе старее> THORIUM_DEB=thorium-browser_154…_arm64.deb \
    port/armbian/build_image.sh Armbian_26.11.0_amlogic_s905l2_bookworm_6.18.51_server_….img.gz \
    desktop out_desktop.img            # или server
sudo port/sdcard/write_image.sh /dev/sdX out_desktop.img
```

Сборка идёт в arm64-chroot (на x86 нужны `qemu-user-static` и `binfmt-support`). e2fsprogs старше
1.47 не понимают ext4 образа (`orphan_file`), поэтому для варианта с рабочим столом (раздел
расширяется на 3 ГБ) их можно собрать из исходников и указать в `E2FSPROGS`.

**Первый запуск.** На экране запускается мастер Armbian: пароль root (сейчас `1234`), новый
пользователь, язык и часовой пояс. В варианте с рабочим столом после этого сам стартует Xfce с
автовходом этого пользователя. Раздел системы растягивается на всю карту (нужна одна перезагрузка).

**Меню загрузки.** Картинка `bootmenu/bootmenu.bmp` (1920×1080, 16 бит RGB565 — 24-битную U-Boot
рисует со сдвигом и не теми цветами) и скрипт `bootmenu/s905_autoscript.cmd`: 10 секунд ждёт кнопку
пульта командой `irkey`: вправо — Armbian, влево, OK или без нажатия — Android (с 03.10.2026;
в образах v1.2 из релиза без нажатия ещё грузится Armbian — на записанной карте это
меняется копированием `s905_autoscript`, `s905_autoscript.cmd` и трёх `bootmenu*.bmp` из
`bootmenu/` на раздел BOOT).
Выбор сразу подтверждается картинкой `bootmenu_android.bmp` / `bootmenu_armbian.bmp` (выбранная
система в рамке, «Загрузка …»); все три рисует `make_bootmenu_bmp.py <папка>`. Перед уходом в
Android скрипт через секунду очищает экран загрузчика (`osd clear`). Телевизору нужно 2–4 с, чтобы
поймать HDMI, поэтому ожидание 10 с, а не 5.
Загрузчик порта v1.2 сам выполняет `s905_autoscript` с карты и умеет `irkey`. Со старым загрузчиком
(v1.0/v1.1) карту нужно один раз активировать (шаг 5 ниже), а меню просто сразу грузит Armbian.

**Карта.** Берите хорошую. Наша 16-гигабайтная карта за день работы перешла в режим «только
чтение» — так карты сообщают об отказе — и перед этим отдавала часть данных с ошибками: падал
systemd, «пропадал» `/sbin/init`. `write_image.sh` проверяет запись чтением, но износ проявляется
позже.

## Состояние

| | |
|---|---|
| Загрузка | с microSD через наш U-Boot (mainline U-Boot ophub не читает SD на S905L2) |
| CPU / ОЗУ | 4 × Cortex-A53 до 1,512 ГГц (с загрузчиком порта v1.2; со старым — 1,2 ГГц), 785 МБ + zram 392 МБ + файл подкачки 1 ГБ |
| HDMI | Xorg (modesetting + glamor на Mali-450), режим — предпочтительный режим монитора/ТВ по EDID (см. «Экран») |
| Звук | HDMI и AV, частота точная (биты MPLL ставит наш U-Boot с v1.3; маршрут в микшере) |
| GPU | Mali-450 MP2 (lima, OpenGL ES 2.0), 125–744 МГц по нагрузке (в DTB ophub ступени 666 и 744 МГц выключены, у нас включены — как в Android) |
| Видео | аппаратно H.264 до 1080p через `yt-play` (ffmpeg); VP9 и HEVC — программно |
| Ethernet | 100 Мбит |
| Wi-Fi | AP6181: ~3,2 МБ/с (26 Мбит/с) приём, пинг 1–3 мс; прошивка чипа из Android обязательна |
| Пульт | родной (NEC 0x4040), 30 кнопок, режим мыши (кнопка «мышь») |
| Индикатор | синий/красный, роли как в Android: окно «Индикатор» в настройках |
| USB | хост (мышь, клавиатура); режим устройства для отладки — по желанию |
| microSD | high speed, чтение 20,8 МБ/с, запись 11,2 МБ/с |
| eMMC | отключена в нашем DTB: на ней Android, Armbian её не видит и не трогает |
| Рабочий стол | Xfce + LightDM, автовход, русский язык, раскладки us/ru (Alt+Shift) |
| Программы | Thorium 154 (`gz83/thorium`) + enhanced-h264ify, mpv, `yt-play` |
| Сон | не поддерживается (ядро не предлагает ни одного состояния сна) |

## Установка вручную (что делает build_image.sh)

1. **Образ.** Скачайте `Armbian_*_amlogic_s905l2_bookworm_*_server_*.img.gz` из релизов ophub.
2. **Запись на microSD** (от 8 ГБ, лучше 16–32 ГБ хорошей марки). В картридере ПК:
   `sudo port/sdcard/write_image.sh /dev/sdX Armbian_….img.gz`. Скрипт после записи сверяет всё
   чтением: дешёвые изношенные карты часто «принимают» запись и не сохраняют её (у нас так
   отказали две карты «NCard»).
3. **Отключите mainline U-Boot из образа.** Переименуйте на разделе BOOT `u-boot.ext` (например,
   в `u-boot.ext.disabled`). mainline U-Boot не читает microSD на S905L2 и уходит в загрузку по сети.
   Без этого файла ядро грузит наш U-Boot, у которого SD работает.
4. **DTB платы.** Положите `meson-gxl-s905l2-rombica-a2.dtb` в `BOOT/dtb/amlogic/` (или соберите:
   `make_dtb.sh <meson-gxl-s905l2-x7-5g.dtb из образа> out.dtb`) и в `BOOT/uEnv.txt` укажите
   `FDT=/dtb/amlogic/meson-gxl-s905l2-rombica-a2.dtb`.
5. **Активация загрузки с SD** (один раз). Карта в приставке, USB-кабель к ПК, приставка в
   Android:
   ```bash
   adb reboot update                 # наш U-Boot уходит в USB-режим прошивки
   port/tools/bin/update bulkcmd "fatload mmc 0 1020000 aml_autoscript"
   port/tools/bin/update bulkcmd "autoscr 1020000"   # прописывает автозапуск с SD/USB, перезагрузка
   ```
   Без ПК (`reboot update` без USB-кабеля, наш U-Boot сам выполняет `aml_autoscript` с карты)
   должно работать по env U-Boot, но не проверялось.
6. **Первый вход:** `ssh root@<IP>` (пароль `1234`), мастер попросит сменить пароль и создать
   пользователя. Для входа по ключу: `ssh-copy-id root@<IP>`.
7. **Звук.**
   - Частоту звука исправляет загрузчик порта v1.3 (см. «Почему нужны правки»), в системе для
     этого ничего не нужно. С загрузчиком v1.2 и старше звук идёт на ~16% медленнее.
   - Включите маршрут в микшере: по умолчанию все выходы отключены (`DISABLED`). Затем сохраните
     настройки:
     ```bash
     amixer -c 0 sset "AIU HDMI CTRL SRC" I2S     # HDMI
     amixer -c 0 sset "AIU ACODEC SRC" I2S        # аналоговый выход (AV)
     amixer -c 0 sset "AIU ACODEC OUT EN" on
     amixer -c 0 sset ACODEC 90% unmute
     alsactl store
     ```
   - Если ползунок громкости в панели «не работает», проверьте громкость PulseAudio:
     `pactl set-sink-volume @DEFAULT_SINK@ 70%` (у нас после установки она была 0%).
8. **Подкачка** (без неё система виснет от нехватки памяти, например, с браузером). Копии
   настроек — в `files/`:
   ```bash
   apt install zram-tools
   cp files/zramswap /etc/default/zramswap && systemctl restart zramswap   # zstd, 50%, prio 100
   fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile
   echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab && swapon -a
   cp files/90-zram.conf /etc/sysctl.d/                                     # swappiness 100
   ```
9. **Рабочий стол** (так настроено у нас):
   - `apt install --no-install-recommends xserver-xorg xinit xfce4 xfce4-terminal xfce4-xkb-plugin
     lightdm lightdm-gtk-greeter pulseaudio pavucontrol network-manager-gnome dbus-x11 policykit-1`;
   - автовход: `/etc/lightdm/lightdm.conf.d/50-autologin.conf` с
     `autologin-user=<пользователь>`, `autologin-session=xfce`, пользователь в группе `autologin`;
   - экран: `files/20-meson-display.conf` → `/etc/X11/xorg.conf.d/` (см. «Экран»);
   - язык и время: `LANG=ru_UA.UTF-8` в `/etc/default/locale`, `timedatectl set-timezone
     Europe/Kyiv`, раскладки в `/etc/default/keyboard`: `XKBLAYOUT="us,ru"`,
     `XKBOPTIONS="grp:alt_shift_toggle"`;
   - композитор xfwm4 выключен (Настройки → Диспетчер окон, доп. → Композитный менеджер): он
     работает на процессоре и ничего не даёт.
10. **Wi-Fi** (подробности — в разделе «Почему нужны правки»):
    - прошивка чипа из Android: `device_info/wifi_40181/fw_bcm40181a2.bin` →
      `/lib/firmware/brcm/brcmfmac43362-sdio.rombica,smartbox-a2.bin`;
    - nvram: `brcmfmac43362-sdio.rombica,smartbox-a2.txt` → `/lib/firmware/brcm/`;
    - исправленный `brcmfmac` (патч `brcmfmac-oob-irq-no-wake.patch`, сборка — `build_modules.sh`)
      → `/lib/modules/<версия>/updates/brcmfmac/`, затем `depmod -a`;
    - подключение: `nmcli dev wifi connect "<сеть>" password "<пароль>"`;
    - `files/90-rombica-wifi.conf` → `/etc/NetworkManager/conf.d/`: NetworkManager не бросает
      сохранённую сеть после 4 неудачных попыток (по умолчанию бросает), например, когда роутер
      был выключен дольше приставки;
    - при подключённом Ethernet: `files/80-multihome.conf` → `/etc/sysctl.d/`.
11. **Пульт:** `rombica_a2.toml` → `/etc/rc_keymaps/`, в `/etc/rc_maps.cfg` строка
    `meson-ir * rombica_a2.toml`. **Режим мыши:** `apt install python3-evdev`, `rc-mouse` →
    `/usr/local/sbin/`, `rc-mouse.service` → `/etc/systemd/system/`, `systemctl enable --now rc-mouse`.
12. **Индикатор:** драйвер `leds-bicolor-gpio` (`build_modules.sh` →
    `/lib/modules/<версия>/updates/leds/`, `depmod -a`) и узел `led-bicolor` в нашем DTB;
    `files/90-rombica-led.rules` → `/etc/udev/rules.d/`; папка `/etc/rombica-led/`
    (`chown root:users`, `chmod 2775`), в ней `led.conf` (`chmod 664`). Окно «Индикатор»:
    `apt install python3-gi gir1.2-gtk-3.0`, `rombica-led-settings` → `/usr/local/bin/`,
    `rombica-led-settings.desktop` → `/usr/share/applications/`.
13. **YouTube с аппаратным декодированием:** `apt install xclip libnotify-bin`, свежий
    [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases) → `/usr/local/bin/`, `yt-play` →
    `/usr/local/bin/`, `yt-play.desktop` → `/usr/share/applications/`, затем
    `xdg-mime default yt-play.desktop x-scheme-handler/ytplay` (от пользователя) и закладка в
    браузере (в образе — на панели закладок Thorium через политику), адрес: `javascript:(()=>{document.querySelectorAll('video').forEach(v=>v.pause());location.href='ytplay:'+location.href})()`.
    mpv: `files/mpv.conf` → `~/.config/mpv/`.
14. **USB-доступ с ПК** (только для отладки): скрипт `usb-gadget` → `/usr/local/sbin/`,
    `usb-gadget.service`, подключение NetworkManager `nmcli con add type ethernet ifname usb0
    con-name usb-gadget ipv4.method shared ipv4.addresses 10.42.0.1/24`,
    `systemctl enable serial-getty@ttyGS0`. **Служба забирает USB-порт OTG:** мышь или
    клавиатура в этом порту перестанут работать. Включайте её только на время отладки.

## Почему нужны правки

- **HDMI.** В DTB ophub HDMI-передатчик S905L2 описан как у G12A (`meson-g12a-dw-hdmi`, регистры
  0xda800000), а в S905L2 он как у GXL (0xc883a000). Драйвер читал не те регистры
  (`Unsupported HDMI controller (0df0:ad:ba)`). После правки: `Detected HDMI TX controller v2.01a`.
- **Звук.** На S905L2 новые настройки MPLL применяются только после бита защёлки в
  `SAR_ADC_REG12` (0xc11086b0), о чём mainline-ядро не знает, поэтому выход оставался на 248 МГц
  и звук шёл на ~16% медленнее. Это разовая настройка SoC: с битами 0..2 все перестройки частоты
  применяются сразу (так делает и драйвер Amlogic 3.14). С v1.3 их ставит наш U-Boot при
  инициализации платы (`port/bootloader/patches/0004-gxl_p271_v1-set-the-GXLX-MPLL-load-bits.patch`), для любой
  системы; служба `s905l2-mpll-load`, писавшая регистр через `/dev/mem`, удалена.
- **Wi-Fi (AP6181 = Broadcom BCM43362).** Было 43 КБ/с и обрывы. Причины по порядку:
  1. Узел Wi-Fi в DTB ophub описан под MediaTek MT7668. В нашем DTB — `brcm,bcm4329-fmac` с
     отдельной линией прерывания `host-wake` GPIOX_7 (вход gpio-intc 96, активный высокий, как в
     стоковом DTB). Прерывание по шине SDIO (`cap-sdio-irq`) на этой плате не работает.
  2. Штатный `brcmfmac` отвергает эту линию: контроллер GPIO-прерываний Amlogic не умеет
     `enable_irq_wake`, а драйвер считал это фатальным. Патч `brcmfmac-oob-irq-no-wake.patch`
     делает ошибку нефатальной. Модули собирает на ПК `build_modules.sh`: исходники ядра ophub
     (`unifreq/linux-6.18.y`, тег `v6.18.51`), конфигурация ophub (`kernel/config-6.18.51-ophub`
     из `/boot` образа), Arm GNU Toolchain 15.2 (ядро собрано GCC 15) и pahole (в конфигурации
     включён BTF, от него зависит раскладка структур). Модули кладутся в
     `/lib/modules/<версия>/updates/` и имеют приоритет над штатными.
  3. Чужой файл калибровки. Armbian по умолчанию берёт `brcmfmac43362-sdio.txt` от Beelink X2
     (другие `boardflags` и мощности). Родной nvram AP6181 из Android —
     `brcmfmac43362-sdio.rombica,smartbox-a2.txt`; имя совпадает с compatible нашего DTB.
  4. **Прошивка чипа.** С прошивкой из linux-firmware (5.90.247) подключение со временем перестаёт
     проходить: чип принимает от точки доступа EAPOL 1/4, а наш ответ 2/4 до неё не доходит,
     даже после холодного старта и с другим MAC. С прошивкой из Android (5.90.195) подключение
     проходит сразу и держится. Опробованные и **не** понадобившиеся правки драйвера (отключение
     scatter-gather/склейки на SDIO, отключение A-MPDU, `roamoff=1`) не нужны.
  5. **Не ставьте приставку вплотную к роутеру.** При уровне −5…−10 дБм приёмник модуля
     перегружается: роутер снижает скорость до 1 Мбит/с, задержка растёт до секунд, закачки
     встают. Отодвинутая на 1,5–2 м (−36 дБм): ровные 3,2 МБ/с. Так же и в Android.
- **eMMC отключена.** Armbian eMMC не нужна, поэтому узел `mmc@74000` в нашем DTB выключен: Android
  на ней Armbian не видит и не трогает, а `armbian-install` не сможет его стереть. Зависание Android
  на логотипе после тёплой перезагрузки (`error -110 whilst initialising MMC card`) сначала
  списывалось на то, что mainline трогает eMMC. Настоящей причиной оказалась ошибка в ядре Android
  (правка Amlogic в `vsprintf`), её исправляет патч ядра 0009 порта v1.2 (см. основной README).
- **Ethernet и Wi-Fi одновременно.** Оба в одной подсети, ответы уходят не тем интерфейсом.
  Помогает `files/80-multihome.conf`: `net.ipv4.conf.all.arp_ignore=1`, `arp_announce=2`.
- **USB к ПК.** В DTB ophub узел USB-переключателя стоит в режиме `host`, и OTG-порт не может быть
  устройством. В нашем DTB — `otg`. Служба `usb-gadget` переводит порт в режим устройства, заново
  привязывает dwc2 и создаёт сеть ECM (приставка 10.42.0.1) и консоль ACM (`serial-getty@ttyGS0`,
  на ПК `/dev/ttyACM0`, нужен модуль `cdc_acm`). Вернуть порт в хост без перезагрузки:
  `echo host > /sys/class/usb_role/d0078080.usb-role-switch/role`, затем
  `echo c9000000.usb > /sys/bus/platform/drivers/dwc3/unbind` и то же в `bind`.
- **Пульт.** Раскладка взята из стокового DTB (`cyxtech-remote-cs918`), кнопки «мышь» (0x44)
  в ней нет — добавлена как `KEY_PROG1`. Режим мыши в Android делает драйвер пульта Amlogic в
  ядре; в mainline его нет, поэтому `rc-mouse`: пульт захватывается (evdev grab), стрелки
  двигают курсор с ускорением (от 2 до 24 точек за 20 мс, разгон 1,2 с), OK — левая кнопка,
  «Меню» — правая, PageUp/PageDown — колесо, остальные кнопки проходят как есть.
- **Индикатор.** Светодиод двухцветный на одной ножке GPIODV_24: высокий уровень — синий,
  низкий — красный, вход — погашен. В mainline нет драйвера для такого диода, поэтому свой:
  `leds-bicolor-gpio` (`leds-bicolor/`, как sysled в нашем Android) — два светодиода
  `rombica:blue` и `rombica:red` со штатными триггерами ядра, узел `led-bicolor` в DTB
  (`make_dtb.sh`). Роль цвета — триггер: `none`, `default-on`, `heartbeat`, `mmc1` (microSD),
  `rc-feedback` (пульт, срабатывает в ядре и в режиме мыши). Выбор хранится в
  `/etc/rombica-led/led.conf`, при загрузке его применяет udev (`90-rombica-led.rules`), окно
  «Индикатор» меняет триггер сразу. Ни службы, ни опроса (раньше — демон на Python).

## Видео и браузер

- **Браузер без GPU.** Chromium (и Thorium) требует OpenGL ES 3, а у Mali-450 только ES 2.0:
  процесс GPU завершается (`GLES3 is unsupported`), страница, видео и его масштабирование
  рисуются процессором. Аппаратного декодирования в браузере нет (Chromium для Linux умеет только
  VA-API, а декодер Amlogic — V4L2). Это ограничение железа.
- **Главная нагрузка — масштабирование.** Thorium, локальный файл, экран → видео:

  | Экран | Видео | Потеряно кадров | CPU |
  |---|---|---|---|
  | 1080p | 360p на весь экран | 77% | 240% |
  | 1080p | 360p/480p без масштаба | 0% | ~180% |
  | 1080p | 1080p | почти всё (~4 кадр/с) | 355% |
  | 720p | 720p H.264 / VP9 / AV1 | ~0% | 240–290% |

  Поэтому экран по умолчанию 1280×720, а YouTube в браузере — 720p. Программное декодирование
  (ffmpeg, 4 потока): VP9 стоит столько же, сколько H.264, AV1 — в 1,7–2,2 раза дороже.
  Расширение enhanced-h264ify (для Chromium-браузеров) полезно только тем, что отключает AV1, и
  галочкой «Block 60fps».
- **Какой браузер легче** (чистый профиль, загрузка страницы, 30 с; CPU-секунды и память PSS):

  | | Википедия | BBC News | GitHub | YouTube |
  |---|---|---|---|---|
  | Thorium 154 | 27 с, 177 МБ | 26 с, 229 МБ | 31 с, 196 МБ | 720p |
  | **Falkon** (QtWebEngine 5.15) | **6 с, 145 МБ** | **22 с, 179 МБ** | **24 с, 175 МБ** | не рисуется |
  | GNOME Web (WebKitGTK 2.50) | 25 с, 208 МБ | 28 с, 146 МБ | 29 с, 122 МБ | не стартует |

  Чистые замеры в пользу Falkon, но на деле он и GNOME Web ощущались «туже» и открывают не все
  сайты: у Falkon старый движок (Chromium 87), YouTube в нём не рисуется; в WebKitGTK YouTube не
  стартует. Поэтому в образе — **Thorium** (современный движок, расширения), с enhanced-h264ify
  (политика `files/rombica-h264ify.json`) и закладкой «▶ HW» на панели (`files/rombica-bookmarks.json`).
  Видеочип помогает только WebKitGTK и старому Chromium: оба работают с OpenGL ES 2 (`webkit://gpu`:
  canvas, WebGL, сборка страницы — аппаратно); GNOME Web умеет и аппаратный H.264 через GStreamer
  (`v4l2h264dec`: 1080p без потерь, ~150% CPU), но только без песочницы WebKit — она не пропускает
  `/dev/video0`.
- **Аппаратный H.264: `yt-play`.** Декодер meson-vdec тянет 1080p H.264 со скоростью ~135 кадр/с,
  но mpv 0.35 падает на нём при любом способе подключения, а на сливе последних кадров декодер
  зависает. `yt-play` берёт у yt-dlp потоки H.264 (до 1080p) и звука, ffmpeg декодирует видео
  аппаратно и передаёт кадры NV12 в mpv, который только масштабирует их на GPU. Потоки выше
  30 кадр/с показываются с 30 кадр/с (копирование 60 кадров 1080p в секунду не успевает).
  Результат, 1080p на весь экран: ~1 потерянный кадр за 20 с, звук синхронен, ~75–160% CPU.
  Перемотки нет (вход — поток). Запуск: закладка «▶ HW» на странице ролика, ярлык «YouTube
  (аппаратно)» (берёт ссылку из буфера обмена) или `yt-play <ссылка> [720]`.
- **Прочее:** MPEG-2 на аппаратном декодере вешает его (сброс — перезагрузка модуля
  `meson_vdec`); VP9 и HEVC аппаратно недоступны (у S905L2 нет VP9, для HEVC на GXL нет
  mainline-драйвера). mpv сам по себе — программное декодирование: H.264 1080p30 с редкими
  потерями, 1080p60 не тянет.

## Удалённый рабочий стол (RustDesk)

Официальный RustDesk 1.4.9 (arm64) работает, но декодирует программно в один поток: пара
кадров в секунду на экране 2560×1080. RustDesk вместе с браузером не помещается в 785 МБ
(система встаёт, отваливается Wi-Fi). Аппаратный H.264 (meson-vdec) быстрый, но придерживает
2–3 кадра. Подробности, замеры и пробники — `rustdesk/README.md`. Для удалённой работы лучше
Android со сборкой `port/apps/rustdesk`.

## Экран

С v1.3 режим экрана выбирает приёмник: ядро (meson-drm) и Xorg берут предпочтительный режим из
EDID, то есть у монитора — его родное разрешение (например, 1280×1024), у ТВ — обычно 1080p.
Раньше образ навязывал 1080p в командной строке ядра (`video=HDMI-A-1:1920x1080@60e` от ophub)
и 1280×720 в Xorg — на мониторах это давало «вход не поддерживается» или растянутую картинку.
Для видео в браузере выгоднее 720p (меньше масштабирования на процессоре): выбирается в
Настройки → Дисплей и сохраняется для пользователя. Загрузочное меню U-Boot на мониторах другого
соотношения сторон показывается с полями, без растяжения. Курсор программный: у контроллера
дисплея meson-drm нет плоскости курсора, и при движении курсор может мерцать.

## Аудит (30.09–02.10.2026)

| | |
|---|---|
| CPU | 7-Zip, 4 потока: 3382 MIPS на 1,2 ГГц, 3720–3950 на 1,512 ГГц; 15 мин полной нагрузки на 1,512 ГГц — без ошибок, максимум 69 °C с радиатором (троттлинг с 80 °C) |
| Память | ~3 ГБ/с |
| microSD | 20,8 МБ/с чтение, 11,2 МБ/с запись, 4K: ~205 / ~136 IOPS |
| eMMC | в Armbian отключена (до этого: HS200 на 25 МГц, 20,7 МБ/с) |
| GPU | glmark2-es2 1280×720 (вне экрана): 109 при 500 МГц, 136–148 при 744 МГц; 4 прогона подряд — стабильно, 55 °C с радиатором |
| Wi-Fi | 3,2 МБ/с приём по локальной сети, 2,9 МБ/с из интернета (на расстоянии от роутера) |
| Пульт | все кнопки, режим мыши |
| Сон | не поддерживается (`/sys/power/state` пуст) |
| dmesg | без ошибок, кроме известных безвредных |

## Осторожно

- **Не запускайте `armbian-install`.** Он переносит систему на eMMC и сотрёт Android.
- **`armbian-update`** (обновление ядра) может заменить набор DTB. После обновления проверьте, что
  `meson-gxl-s905l2-rombica-a2.dtb` и строка `FDT` в `uEnv.txt` на месте. Исправленный `brcmfmac`
  из `updates/` к новому ядру не подойдёт: его надо пересобрать.
- **Загрузить Android с вставленной картой:** в меню нажать на пульте **влево**.
- **Вернуть «только Android»:** достаточно вынуть карту. Сбросить env U-Boot к исходному можно
  из USB-режима: `update bulkcmd "env default -a"`, затем `update bulkcmd "saveenv"`.
- **Один раз загрузить Android, не вынимая карту:** `touch /boot/boot_android && reboot`.
  Скрипт загрузки чередует системы, пока файл лежит на карте: следующая перезагрузка вернёт
  Armbian. Потом удалите файл.

## Не сделано

1. **RustDesk:** задать постоянный пароль (`rustdesk --password …`, пароль выбирает владелец),
   проверить сеанс и нагрузку. Кодирование программное; экран 1280×720 здесь тоже помогает.
2. **Долгий стресс-тест карты.** Редкие сбои чтения при распаковке (3 случая) оказались, судя по
   всему, началом отказа прежней 16-гигабайтной карты: через день она перешла в режим «только
   чтение». На новой карте 32 ГБ сбоев не было, но многочасовой тест ввода-вывода не проводился.
3. **Проверка образа v1.3** (08.10.2026 не завершена). Записанный на карту 4 ГБ (MCARD) образ
   server v1.3 (MD5 сверен чтением) не загрузился: ядро повторяет «error -84 whilst initialising
   SD card» (ошибка CRC при инициализации карты) и не находит корневой раздел. U-Boot читает с
   этой карты ядро и initrd, ядро Android Amlogic читает весь образ без ошибок (19,5 МБ/с, то
   есть в режиме high speed), а Armbian с тем же ядром 6.18.51 работал на карте 16 ГБ (логи
   UART). DTB v1.3 отличается от v1.2 только узлом индикатора (GPIODV_24, не выводы карты), так
   что это, скорее всего, особенность карты с драйвером mainline (`meson-gx-mmc` ставит
   фиксированные фазы такта и для high speed их не подстраивает), а не изменение v1.3 — не
   проверено. Нужен лог ядра по UART: на каком шаге (идентификация или переход в high speed)
   карта перестаёт отвечать.
