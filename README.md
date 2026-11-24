# NovaGKI

GKI kernels for Android devices on Linux 5.10, 5.15, 6.1, 6.6 and 6.12, with FinaSU or BakaSU root, SuSFS hiding, KMI-safe hardening and performance tuning.

> [!NOTE]
> **Based on [GKID Kernels](https://github.com/ahmed-alnassif/GKID-Kernels) by [Ahmed Al-Nassif](https://github.com/ahmed-alnassif).**
> NovaGKI is a fork of GKID's `dev` branch at [`ef6c99d`](https://github.com/ahmed-alnassif/GKID-Kernels/commit/ef6c99dc6fc10f120cc02c37e721ab959a2fbd9c) (October 2026). Most of the build system, patches and configs come from GKID; [What's different from GKID](#whats-different-from-gkid) lists what changed here. GKID's own 6.1 kernel source is [GKI-Duchamp-6.1](https://github.com/ahmed-alnassif/GKI-Duchamp-6.1). For the original project, its releases and its community, go to GKID.

## Will it work on my device?

These are GKI kernels: one image per kernel line, for every device whose stock kernel is a GKI kernel on that line. No device-specific source is needed.

| Linux | Android | GKI KMI | `uname -r` contains |
|---|---|---|---|
| 5.10 | 12 | `android12-5.10` | `5.10.` and `android12` |
| 5.15 | 13 | `android13-5.15` | `5.15.` and `android13` |
| 6.1 | 14 | `android14-6.1` | `6.1.` and `android14` |
| 6.6 | 15 | `android15-6.6` | `6.6.` and `android15` |
| 6.12 | 16 | `android16-6.12` | `6.12.` and `android16` |

Check Settings → About phone → Kernel version, or run `uname -r`, and download the zip for the matching line. The Android number in the kernel version is the release the kernel was built for, which can be older than the Android version your phone runs now. The installer stops if the running kernel isn't on the zip's Linux version.

> [!IMPORTANT]
> Only the KMIs in the table are built. Devices on `android13-5.10` or `android14-5.15` have the same Linux version but a different KMI. The installer won't stop you, but vendor modules may not load.

Every line builds from AOSP's GKI kernel source.

> [!WARNING]
> Back up your stock `boot.img` before flashing. If a build doesn't boot, flashing it back from recovery or fastboot is the way out.

## Variants

Each release has one zip per variant for each kernel line, named `NovaGKI-<variant>-<release>-<Linux version>.zip`:

| Variant | Root | Manager app | NoMount |
|---|---|---|---|
| **FinaSU+SuSFS** | [FinaSU](https://github.com/LyraVoid/FinaSU) | [FinaSU manager](https://github.com/LyraVoid/FinaSU/releases) | FinaSU's own driver, loaded by FinaSU |
| **BakaSU+SuSFS** | [BakaSU](https://github.com/Baka-SU/BakaSU) | [BakaSU manager](https://github.com/Baka-SU/BakaSU) | Built in when the build's `NM` option is on |

Both include SuSFS v2.4.0, Baseband Guard, NTSync, BBRv3 and the hardening and hiding changes below. Neither has KPM.

Releases are published as pre-releases named `vYY.MM.DD-rN` on the [Releases](../../releases) page.

## Installing

1. Download the zip for your kernel line and variant from [Releases](../../releases).
2. Flash it with one of:
   - your root manager's **Install AnyKernel3** option (FinaSU and BakaSU both have it)
   - a custom recovery (TWRP, OrangeFox, …)
   - a kernel flasher app
3. Reboot and install the manager app for that variant. The FinaSU kernel trusts only the official FinaSU manager.

### Switching between FinaSU and BakaSU

You can flash one variant over the other from the running manager. Afterwards:

- **Manager:** install the new variant's manager. The old one won't control root any more.
- **NoMount:** use one source.
  - If [maxsteeel's NoMount](https://github.com/maxsteeel/nomount) module was installed while NoMount was built into your kernel, the module deleted its own driver during install. FinaSU steps aside for that module, so on a FinaSU kernel neither driver loads.
  - Fix it by reinstalling the module, or by uninstalling it and choosing NoMount in FinaSU's mount settings.
- **FinaSU's NoMount and hiding:** every app sees module files until you exclude it. Go to NoMount → **Excluded apps** → **Follow app profiles** → **Save** to hide them from non-root apps, as the default mount mode does. Repeat after installing apps or changing profiles.
- **SuSFS settings:** [ReSuSFS](https://github.com/ahmed-alnassif/ReSuSFS) works on both variants. FinaSU also has its own SuSFS page, which does nothing until you configure it. Use one or the other so they don't overwrite each other.

## Checking a flashed build

[`scripts/post-flash-check.sh`](scripts/post-flash-check.sh) runs on the phone as root. It reports PASS, FAIL or SKIP for each of these:

- the running kernel is this build
- vendor modules load without `Unknown symbol` errors
- the wakelock cap
- the unicode path fix
- `/proc/config.gz` hiding
- s2idle
- SysV IPC on DroidSpaces and NetHunter builds

```sh
adb push scripts/post-flash-check.sh /data/local/tmp/
adb shell sh /data/local/tmp/post-flash-check.sh
```

Add `--suspend` to also check that the phone still suspends. The exit status is the number of failures.

## What's different from GKID

**Root**
- **FinaSU + SuSFS variant (new):**
  - Uses SuSFS inline hooks and has preinit enabled.
  - Trusts the FinaSU release manager through the kernel's second signature slot. The certificate is read from the latest FinaSU release APK at build time.
  - The build stops if any of this is missing, instead of shipping a kernel the manager can't see.
- **BakaSU SELinux types:** the types BakaSU injects (`ksu`, `ksu_file` and module types) are registered with SuSFS, so SELinux context probes such as Duck Detector's can't confirm them.

**Kernel source and build**
- **6.1 source:** built from AOSP's `android14-6.1` instead of GKID's [GKI-Duchamp-6.1](https://github.com/ahmed-alnassif/GKI-Duchamp-6.1) device tree. 6.1 now gets the same patch set as the other lines and AOSP fixes as soon as they land, instead of waiting for the device tree to be merged by hand.
- **Source branches:** 6.1 and 6.6 build from the main GKI branches (`android14-6.1`, `android15-6.6`), which Google builds GKI releases from and which get Android security fixes first. GKID used `android15-6.6-lts` for 6.6.
- **AutoFDO:** uses the sample profile Google ships in the GKI tree (6.6 and 6.12).
- **KMI check:** after each build, compares the kernel's exported symbols with Google's GKI ABI on every line. It reports which symbols that phone makers' modules use have changed or gone missing, per vendor symbol list, and ignores symbols exported by Android's own GKI modules. The full list is saved as `kmi-report-<line>-<variant>.txt` in the build artifacts. By default this only warns.
- **Stock-style kernel name (optional, `STOCK_NAME`):**
  - Reports a stock-style release (for example `-android15-8-g…`) instead of `-NovaGKI-rN-…`.
  - Can copy a stock kernel's builder, compiler and build date.
  - Always keeps the real patch level, because faking it stops vendor modules from loading and bootloops the phone.
- **CI:** builds the BakaSU and FinaSU variants for the kernel line you pick, or all lines. Telegram posting and the Telegram upload workflow are removed.

**Security and hiding**
- **Hardening (KMI-safe):** heap memory is zeroed on free, the kernel stack offset is randomized on every syscall, and call-used registers are zeroed on return.
- **`/proc/config.gz`:** reports root-related options as not set (KernelSU, SuSFS, KPM, NoMount, Baseband Guard).
- **Unicode path fix:** paths containing zero-width characters (for example `Android/data` with a U+200B inside) no longer resolve to the real folder. This closes a known `Android/data` access bypass.

**Fixes**
- **Wakelock cap:** the 500 ms cap that GKID's README advertised is now applied. Userspace wakelocks without a timeout expire after 500 ms.
- **BBRv3:** now on every GKI line. New backports for 5.10, 5.15 and 6.12, and a rebased patch for 6.6.
- **SIMD `memcmp` removed on 6.1, 6.6 and 6.12:** it could corrupt a user thread's FP/SIMD registers.
- **Dropped patches:** `int_sqrt` (slower and wrong for very large inputs) and `lib/string` (unused on arm64).
- **Patch rebases:** patches are rebased per GKI line and checked against current AOSP.
- **Post-flash check:** added the on-device check script.
- **Build identity:** kernels are named NovaGKI (`uname -r` shows `-NovaGKI-rN-…`), report your repo's owner as the builder (`/proc/version`) and use UTC for release dates. The installer shows NovaGKI's banner and links to this repo's issues instead of GKID's Telegram, and no longer credits GKID's author as the builder.

## What's inside

**Performance**
- 300 Hz timer
- MGLRU forced on (5.15 and later; 5.10 doesn't have it)
- zRAM with LZ4 and writeback
- schedutil and ondemand governors
- mq-deadline I/O scheduler
- Optimized arm64 memory routines
- Scheduler tweaks: CPU scan order, `CACHE_HOT_BUDDY` off
- NTSync driver for Windows games and apps in Winlator and GameHub

**Storage**
- F2FS: 50 ms urgent GC sleep, shorter uncongestion timeout, larger `min_fsync_blocks`
- ext4: longer default commit age, so fewer writes

**Battery**
- 500 ms wakelock cap
- 1 s freezer timeout
- Minimized alarm wakeups
- s2idle wake-attempt gate
- Less log spam

**Networking**
- BBRv3 as the default congestion control, plus Westwood+
- FQ-CoDel and FQ
- IP sets
- IPv4 and IPv6 NAT
- IPsec
- Extra netfilter targets and matches for firewalls and tethering

**Security**
- SuSFS v2.4.0: hides paths, mounts, kstat, memory maps and KernelSU/SuSFS symbols; spoofs uname and cmdline/bootconfig; supports open redirect
- Baseband Guard: blocks unauthorized writes to critical partitions
- The hardening above

**Build options**
- **DroidSpaces:** Linux containers (SysV IPC, namespaces, devtmpfs, netfilter for UFW and Fail2ban)
- **NetHunter:** monitor mode and packet injection, Realtek rtw88 and other USB Wi-Fi drivers, Bluetooth HCI, SDR. Wireless drivers built as modules ship as a separate `WirelessKSU` module zip.
- **NoMount:** built into BakaSU kernels when `NM` is on

### Switching TCP congestion control

The change lasts until reboot:

```sh
su -c "sysctl -w net.ipv4.tcp_congestion_control=westwood"   # Westwood+, can do better on Wi-Fi and mobile data
su -c "sysctl -w net.ipv4.tcp_congestion_control=bbr"        # BBRv3, the default
```

To make it permanent, put the command in a script in `/data/adb/service.d/`.

## Building

Builds run on GitHub Actions. Open the Actions tab, select **NovaGKI Builder** ([`.github/workflows/build.yml`](.github/workflows/build.yml)) and click **Run workflow**. Every `kernel` run publishes a pre-release with all the lines it built. Jobs run two at a time, so an `All` run (10 jobs) takes about five times as long as a single line.

| Input | Default | What it does |
|---|---|---|
| `TODO` | `kernel` | `kernel` builds and releases; `defconfig` only exports the generated config |
| `TEST` | `no` | `yes` runs the pipeline without compiling |
| `LTO` | `fullLTO` | `fullLTO`, `thinLTO` or `noneLTO` |
| `KERNEL_VERSION` | `All` | Kernel line to build: `All`, `5.10`, `5.15`, `6.1`, `6.6` or `6.12` |
| `CLEAN_LTO_CACHE` | on | Clears the ThinLTO cache first |
| `DROIDSPACES` | on | DroidSpaces support |
| `NH` | on | NetHunter drivers and patches |
| `NM` | off | Builds NoMount into BakaSU kernels (FinaSU always uses its own) |
| `AUTOFDO` | on | Uses the in-tree AutoFDO profile |
| `HARDENING` | on | KMI-safe hardening |
| `STOCK_NAME` | off | Reports a stock GKI-style kernel release |
| `STOCK_VERSION` | empty | With `STOCK_NAME`: a stock `Linux version …` line, or just a release suffix, to copy from |

`build.sh` also reads these environment variables:

| Variable | What it does |
|---|---|
| `FINASU_REF` | FinaSU branch or tag to build (default `dev`) |
| `FINASU_CERT_SIZE`, `FINASU_CERT_HASH` | Manager certificate to trust; skips the APK download |
| `KMI_STRICT=true` | Fails the build when a symbol vendor modules use has a changed CRC or is missing |

`build.sh` also supports the Vanilla, KernelSU, Compat and NoDS variants. To build those, add their names to `VARIANTS` and turn on the matching `BUILD_*` flag in the workflow's matrix step.

## Credits

- [GKID Kernels](https://github.com/ahmed-alnassif/GKID-Kernels) by [Ahmed Al-Nassif](https://github.com/ahmed-alnassif): the original project this is based on, plus [GKI-Duchamp-6.1](https://github.com/ahmed-alnassif/GKI-Duchamp-6.1), [AK3-GKID](https://github.com/ahmed-alnassif/AK3-GKID) and [ReSuSFS](https://github.com/ahmed-alnassif/ReSuSFS). You can [support his work here](https://github.com/ahmed-alnassif/GKID-Kernels#-support-this-project).
- [SuSFS](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk
- [FinaSU](https://github.com/LyraVoid/FinaSU) by LyraVoid
- [BakaSU](https://github.com/Baka-SU/BakaSU)
- [KernelSU](https://github.com/tiann/KernelSU) by tiann
- [NoMount](https://github.com/maxsteeel/nomount) by maxsteeel
- [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard)
- [WildKernels kernel patches](https://github.com/WildKernels/kernel_patches): NTSync and the hiding patch review
- fake `config.gz` patch by fatalcoder524; wakelock timeout patch by Panchajanya1999
- BBRv3 by Google's BBR team
- [GKI_FinaSU](https://github.com/muling0721/GKI_FinaSU) by muling0721: the FinaSU manager certificate extractor
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) by osm0sis
- [Neutron Clang](https://github.com/Neutron-Toolchains)
- DroidSpaces kernel config by [ravindu644](https://github.com/ravindu644)

## License

GPL-3.0, the same as GKID. See [LICENSE](LICENSE).
