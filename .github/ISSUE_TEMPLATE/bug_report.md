---
name: Kernel Bug Report
about: Report boot issues, crashes, or feature malfunctions
title: "[BUG]: "
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of the issue (e.g., bootloop, WiFi not working, random reboot).

**Device & Environment**
- **Device:** [e.g., Pixel 9 (tokay)]
- **ROM:** [e.g., HyperOS 3.0, AOSP 16]
- **Kernel zip:** [the file you flashed, e.g., `NovaGKI-FinaSU+SuSFS-v26.11.24-r23-6.6.144.zip`]
- **Kernel version:** [output of `uname -r`, e.g., `6.6.144-NovaGKI-r23-a1b2c3d4e5f6`]
- **Stock kernel version:** [`uname -r` before flashing, e.g., `6.6.57-android15-8-g…`]

**To Reproduce**
Steps to reproduce the behavior:
1. Flash the zip via your root manager's Install AnyKernel3, a custom recovery, or a kernel flasher app
2. Reboot device
3. [Describe what triggers the issue]

**Expected behavior**
What you expected to happen (e.g., "Device should boot normally with all features enabled").

**Logs (CRITICAL)**
Please provide **BOTH** logs as a **single ZIP file**:
1. Run `dmesg > /sdcard/dmesg.txt` in terminal
2. Copy pstore log: `cp /sys/fs/pstore/console-ramoops-0 /sdcard/`
3. **Zip both files** and attach here

**Screenshots**
If applicable, add screenshots of error messages or of your root manager (FinaSU / BakaSU).

**Additional context**
- Does the issue occur on one variant only (FinaSU or BakaSU)?
- Output of `scripts/post-flash-check.sh`, if you could run it
- Any recent changes before the bug appeared?
