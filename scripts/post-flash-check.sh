#!/system/bin/sh
# GKID post-flash checks: run on the device after flashing a build.
#
#   adb push scripts/post-flash-check.sh /data/local/tmp/
#   adb shell sh /data/local/tmp/post-flash-check.sh
#
# The script re-runs itself through su when it is not root, so no su
# wrapper is needed (and "su -c sh <file>" does NOT work: su only takes
# the word after -c as the command). From a root shell, or Termux after
# running su, use: sh /data/local/tmp/post-flash-check.sh
#
# Add --suspend [seconds] to also check that the device still suspends
# (lock the screen when prompted; default wait is 300 seconds):
#
#   adb shell sh /data/local/tmp/post-flash-check.sh --suspend
#
# Exit status is the number of FAIL results (0 means everything passed or
# was skipped). Uses only toybox tools that ship with Android.

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  [SKIP] $*"; }
info() { echo "  [INFO] $*"; }
section() { echo; echo "== $*"; }

SUSPEND_WAIT=""
if [ "$1" = "--suspend" ]; then
	SUSPEND_WAIT="${2:-300}"
fi

if [ "$(id -u)" != "0" ]; then
	if [ -z "$GKID_CHECK_ELEVATED" ] && command -v su >/dev/null 2>&1; then
		echo "Not root, re-running through su (approve the prompt in your root manager)..."
		exec su -c "GKID_CHECK_ELEVATED=1 sh '$0' $*"
	fi
	echo "This needs root. Grant Shell root access in your root manager, then run:"
	echo "  su -c 'sh $0'"
	exit 1
fi

# Zero-width space (U+200B) and zero-width joiner (U+200D) as UTF-8
ZWSP="$(printf '\342\200\213')"
ZWJ="$(printf '\342\200\215')"

# --------------------------------------------------------------------------
section "Kernel"
info "$(cat /proc/version)"
# STOCK_NAME builds report a stock version line, so fall back to the compiler
# recorded in the kernel config, which only root can read.
if grep -q GKID /proc/version; then
	pass "running a GKID kernel"
elif grep -q Neutron /proc/version ||
	zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_CC_VERSION_TEXT="Neutron'; then
	pass "running a GKID kernel built with STOCK_NAME"
else
	fail "kernel is not a GKID build (flashed the right image?)"
fi

# --------------------------------------------------------------------------
section "SELinux"
# Permissive SELinux lets any app read /proc/version, netlink link data and
# other surfaces that are normally denied, which undoes most of the hiding.
enforce="$(getenforce 2>/dev/null)"
if [ "$enforce" = "Enforcing" ]; then
	pass "SELinux is enforcing"
else
	fail "SELinux is ${enforce:-unknown}: something with root switched it off after boot"
fi
if dmesg >/dev/null 2>&1; then
	# The kernel logs every switch with the time since boot
	dmesg | grep "enforcing=" | while read -r line; do info "$line"; done
fi

# --------------------------------------------------------------------------
section "Vendor modules (force-load / KABI)"
if dmesg >/dev/null 2>&1; then
	ignored=$(dmesg | grep -c "disagrees about version of symbol .*but ignore")
	unknown=$(dmesg | grep -i "unknown symbol")
	[ "$ignored" -gt 0 ] && info "$ignored symbol version mismatch(es) ignored by the force-load patch"
	if [ -n "$unknown" ]; then
		fail "modules failed to load with unknown symbols:"
		echo "$unknown" | head -n 10 | sed 's/^/         /'
	else
		pass "no 'Unknown symbol' module load failures in dmesg"
	fi
	info "dmesg only holds recent messages; run this soon after boot for a full check"
else
	skip "dmesg not readable"
fi

# --------------------------------------------------------------------------
section "Wakelock cap (add_timeout_wakelocks_globally)"
WL=/sys/power/wake_lock
if [ -w "$WL" ]; then
	name="gkid_check_$$"
	echo "$name" > "$WL"
	if grep -qw "$name" "$WL"; then
		sleep 1
		if grep -qw "$name" "$WL"; then
			fail "wakelock without a timeout is still held after 1s (cap not active)"
		else
			pass "wakelock without a timeout expired within 1s"
		fi
	else
		fail "could not take a test wakelock via $WL"
	fi
	echo "$name" > /sys/power/wake_unlock 2>/dev/null
	info "since Android 12 most wakelocks go through the SystemSuspend service, not $WL"
else
	skip "$WL not available"
fi

# --------------------------------------------------------------------------
section "Unicode bypass fix (zero-width names on casefolded storage)"
MEDIA=/data/media/0
if [ ! -d "$MEDIA/Android/data" ]; then
	skip "$MEDIA/Android/data not found"
else
	flags=$(lsattr -d "$MEDIA" 2>/dev/null)
	flags=${flags%% *}
	casefold=no
	case "$flags" in
		*F*) casefold=yes; info "$MEDIA is casefolded (flags $flags)" ;;
		*) info "$MEDIA does not show the casefold flag (flags ${flags:-unknown}); the bypass needs casefolding, so it cannot occur here" ;;
	esac

	for base in "$MEDIA" /sdcard; do
		if [ -e "$base/Android${ZWSP}/data" ]; then
			fail "$base/Android<U+200B>/data resolves (zero-width bypass still works)"
		else
			pass "$base/Android<U+200B>/data does not resolve"
		fi
	done

	# Ordinary case-insensitive lookups must keep working
	if [ "$casefold" != "yes" ]; then
		skip "case-insensitive lookup check (storage is not casefolded)"
	elif [ -d "$MEDIA/Download" ]; then
		if [ -d "$MEDIA/download" ] && [ -d "$MEDIA/DOWNLOAD" ]; then
			pass "case-insensitive lookup still works (download -> Download)"
		else
			fail "case-insensitive lookup broken: $MEDIA/download not found"
		fi
	else
		skip "no $MEDIA/Download folder to test case-insensitive lookup"
	fi

	# Names that contain zero-width characters must still be usable
	zw="/sdcard/gkid${ZWJ}check_$$.txt"
	plain="/sdcard/gkidcheck_$$.txt"
	if echo test > "$zw" 2>/dev/null; then
		if [ -e "$zw" ] && [ "$(cat "$zw")" = "test" ]; then
			pass "file with a zero-width joiner in its name can be created and read"
		else
			fail "file with a zero-width joiner in its name cannot be read back"
		fi
		if [ -e "$plain" ]; then
			fail "zero-width name also matches the plain name (ignorable code point still stripped)"
		else
			pass "zero-width name is distinct from the plain name"
		fi
		rm -f -- "$zw"
	else
		skip "could not create a test file in /sdcard"
	fi
fi

# --------------------------------------------------------------------------
section "Fake /proc/config.gz (fake_config)"
if [ -r /proc/config.gz ]; then
	visible=$(zcat /proc/config.gz | grep -E '^CONFIG_(KSU|KPM|NOMOUNT|BBG)(_[A-Za-z0-9_]*)?=')
	hidden=$(zcat /proc/config.gz | grep -cE '^# CONFIG_(KSU|KPM|NOMOUNT|BBG)(_[A-Za-z0-9_]*)? is not set')
	if [ -n "$visible" ]; then
		fail "root/hiding options still visible in /proc/config.gz:"
		echo "$visible" | head -n 10 | sed 's/^/         /'
	elif [ "$hidden" -gt 0 ]; then
		pass "$hidden KSU/SuSFS/NoMount/BBG options reported as not set"
	else
		info "no KSU/SuSFS/NoMount/BBG options at all (expected on Vanilla builds)"
	fi
	if zcat /proc/config.gz | grep -q '^CONFIG_LSM=.*baseband_guard'; then
		info "CONFIG_LSM still lists baseband_guard (also visible in /sys/kernel/security/lsm)"
	fi
	info "open the root manager and confirm root still shows as working"
else
	skip "/proc/config.gz not available"
fi

# --------------------------------------------------------------------------
section "s2idle wake gate (0019)"
if [ -r /sys/power/mem_sleep ]; then
	ms=$(cat /sys/power/mem_sleep)
	case "$ms" in
		*"[s2idle]"*) info "suspend mode is s2idle ($ms): the change is active" ;;
		*) info "suspend mode is not s2idle ($ms): the change has no effect on this device" ;;
	esac
else
	skip "/sys/power/mem_sleep not available"
fi

STATS=/sys/power/suspend_stats
if [ -n "$SUSPEND_WAIT" ]; then
	if [ -r "$STATS/success" ]; then
		s0=$(cat "$STATS/success"); f0=$(cat "$STATS/fail")
		info "lock the screen now; waiting ${SUSPEND_WAIT}s (success=$s0 fail=$f0)"
		sleep "$SUSPEND_WAIT"
		s1=$(cat "$STATS/success"); f1=$(cat "$STATS/fail")
		info "after wait: success=$s1 fail=$f1"
		if [ "$s1" -gt "$s0" ] && [ "$f1" -eq "$f0" ]; then
			pass "device suspended $((s1 - s0)) time(s) with no failures"
		elif [ "$f1" -gt "$f0" ]; then
			fail "$((f1 - f0)) suspend failure(s); see $STATS/last_failed_dev"
		else
			fail "device never suspended (screen on, charging, or a wakelock held?)"
		fi
	else
		skip "$STATS not available"
	fi
else
	info "run with --suspend to check that the device still suspends"
fi

# --------------------------------------------------------------------------
section "SysV IPC for DroidSpaces/NetHunter (sysvipc KABI patch)"
if [ -r /proc/config.gz ] && zcat /proc/config.gz | grep -q '^CONFIG_SYSVIPC=y'; then
	if [ -r /proc/sysvipc/shm ] && [ -r /proc/sysvipc/sem ]; then
		pass "SysV IPC is enabled (/proc/sysvipc present)"
		info "inside a container, 'ipcmk -M 4096 && ipcs -m' should list the segment"
	else
		fail "CONFIG_SYSVIPC=y but /proc/sysvipc is missing"
	fi
else
	skip "SysV IPC not enabled in this build (only DroidSpaces/NetHunter builds have it)"
fi

# --------------------------------------------------------------------------
echo
echo "== Result: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
