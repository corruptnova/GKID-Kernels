#!/usr/bin/env python3

import glob
import os
import re

KERNEL_VERSION_ORDER = ["5.10", "5.15", "6.1", "6.6", "6.12"]


def read_or_default(path, default="*No changelog available*"):
	if os.path.isfile(path):
		return open(path).read().rstrip("\n")
	return default


def slugify(text):
	text = text.lower()
	text = re.sub(r"[^\w\s-]", "", text)
	text = re.sub(r"\s+", "-", text.strip())
	return text


def parse_env_file(path):
	env = {}
	with open(path) as f:
		for line in f:
			line = line.strip()
			if "=" in line:
				key, value = line.split("=", 1)
				if key:
					env[key] = value
	return env


def load_build_envs():
	env_files = sorted(glob.glob("release-artifacts/build-env-*.txt"))
	if not env_files:
		raise SystemExit("ERROR: no build-env-*.txt files found in release-artifacts/")

	all_builds = [parse_env_file(f) for f in env_files]

	shared_env = {}
	for key in ("RELEASE_REPO", "RELEASE", "RELEASE_NAME", "KERNEL_NAME"):
		values = {b[key] for b in all_builds if b.get(key)}
		if not values:
			raise SystemExit(f"ERROR: missing required build-env value: {key}")
		shared_env[key] = sorted(values)[0]

	return all_builds, shared_env


def kernel_versions_present(all_builds):
	present = {b.get("KERNEL_VERSION") for b in all_builds if b.get("KERNEL_VERSION")}
	ordered = [v for v in KERNEL_VERSION_ORDER if v in present]
	ordered += sorted(present - set(ordered))
	return ordered


def variant_zip_name(build):
	"""Reconstruct the exact zip filename build.sh produced for this job."""
	base_name = build.get("BASE_NAME")
	release = build.get("RELEASE")
	linux_version = build.get("LINUX_VERSION")
	if not (base_name and release and linux_version):
		return None
	return f"{base_name}-{release}-{linux_version}.zip"


def variant_link(display_name, filename, repo, tag):
	return f"- [{display_name}](https://github.com/{repo}/releases/download/{tag}/{filename})"


def display_variant_name(build):
	name = build.get("BUILD_VARIANT", "")
	kver = build.get("KERNEL_VERSION", "")
	prefix = f"{kver}-"
	return name[len(prefix):] if name.startswith(prefix) else name


ROOT_NAMES = {
	"FSU": "FinaSU",
	"BSU": "BakaSU",
	"KSU": "KernelSU",
}

LTO_NAMES = {"fullLTO": "Full", "thinLTO": "Thin", "noneLTO": "None"}


def variant_name(build):
	"""The user-facing variant build.sh put in the zip name, e.g. Compat+NoLTO+FinaSU+SuSFS."""
	if build.get("VARIANT"):
		return build["VARIANT"]
	base_name = build.get("BASE_NAME", "")
	if "-" in base_name:
		return base_name.split("-", 1)[1]
	return display_variant_name(build)


def variant_traits(build, inputs):
	"""Root, SuSFS, LTO, Compat and DroidSpaces/NetHunter for one build."""
	name = variant_name(build)
	compat = build.get("KSU_COMPAT") == "true" or name.startswith("Compat+")
	# build.sh turns DroidSpaces/NetHunter off for NoDS and Vanilla builds
	no_ds = build.get("No_DS") == "true" or "NoDS" in name or build.get("KSU") in ("no", "vnlto")
	if "NoLTO" in name:
		lto = "None"
	else:
		lto = LTO_NAMES.get(inputs["lto"], inputs["lto"] or "Unknown")
	return {
		"root": ROOT_NAMES.get(build.get("KSU", ""), "None"),
		"susfs": build.get("KSU_SUSFS") == "true",
		"lto": lto,
		"compat": compat,
		"ds_nh": not no_ds and "true" in (inputs["droidspaces"], inputs["nh"]),
	}


def variant_summary(traits):
	parts = [f"{traits['root']} root" if traits["root"] != "None" else "no root"]
	if traits["susfs"]:
		parts.append("SuSFS")
	parts.append("no LTO" if traits["lto"] == "None" else f"{traits['lto']} LTO")
	if traits["compat"]:
		parts.append("Compat build")
	if not traits["ds_nh"]:
		parts.append("no DroidSpaces/NetHunter")
	return ", ".join(parts)


def variant_table(all_builds, inputs):
	"""Markdown table of the variants actually in this release, plus whether any is Compat/FinaSU."""
	yes_no = lambda v: "✅" if v else "❌"
	rows = {}
	for b in all_builds:
		rows.setdefault(variant_name(b), variant_traits(b, inputs))
	lines = [
		"| Variant | Root | SuSFS | LTO | Compat | DroidSpaces / NetHunter |",
		"|---------|------|-------|-----|--------|-------------------------|",
	]
	for name in sorted(rows, key=lambda n: (n.startswith("Compat"), n)):
		t = rows[name]
		root = t["root"] if t["root"] != "None" else "❌"
		lto = t["lto"] if t["lto"] != "None" else "❌"
		lines.append(f"| {name} | {root} | {yes_no(t['susfs'])} | {lto} | {yes_no(t['compat'])} | {yes_no(t['ds_nh'])} |")
	has_compat = any(t["compat"] for t in rows.values())
	has_finasu = any(t["root"] == "FinaSU" for t in rows.values())
	return "\n".join(lines), has_compat, has_finasu


def build_kernel_section(kernel_version, builds, repo, tag, existing_zips, inputs):
	android_release = builds[0].get("ANDROID_RELEASE", "unknown")
	label = f"Android{android_release}-{kernel_version}-LTS"
	anchor_title = f"{label} Files"

	representative = next((b for b in builds if b.get("KSU_SUSFS") == "true"), builds[0])

	file_lines = []
	for b in sorted(builds, key=lambda b: (variant_name(b).startswith("Compat"), variant_name(b))):
		zip_name = variant_zip_name(b)
		if zip_name and zip_name in existing_zips:
			link = variant_link(variant_name(b), zip_name, repo, tag)
			file_lines.append(f"{link}: {variant_summary(variant_traits(b, inputs))}")
	files_block = "\n".join(file_lines) if file_lines else "- *No build artifacts found*"

	wireless_prefix = f"WirelessKSU-{kernel_version}-"
	wireless_zips = sorted(z for z in existing_zips if z.startswith(wireless_prefix))
	if inputs["nh"] != "true":
		wireless_block = "None (NetHunter disabled for this run)"
	elif wireless_zips:
		wireless_block = "\n".join(
			f"- [{z[:-4]}](https://github.com/{repo}/releases/download/{tag}/{z})"
			for z in wireless_zips
		)
	else:
		wireless_block = "*Built-in driver, no separate module needed*"

	susfs_changelog_file = f"release-artifacts/susfs_changelog-{kernel_version}.txt"
	susfs_version = representative.get("SUSFS_VERSION", "Not included")

	anchor_id = slugify(label)
	section = f"""<a name="{anchor_id}"></a>
## {anchor_title}

**Downloads:**
{files_block}

**Kali NetHunter KernelSU modules:**
{wireless_block}

**Build details:**
- Linux version: {representative.get('LINUX_VERSION', 'unknown')}
- Compiler: {representative.get('COMPILER_STRING', 'unknown')}
- SuSFS: {susfs_version}

**SuSFS changelog for this line (last 5 commits):**

{read_or_default(susfs_changelog_file)}
"""
	return label, section


def build_release_body():
	all_builds, shared_env = load_build_envs()
	repo = shared_env["RELEASE_REPO"]
	tag = shared_env["RELEASE"]
	release_name = shared_env["RELEASE_NAME"]

	existing_zips = {os.path.basename(p) for p in glob.glob("release-artifacts/*.zip")}
	versions = kernel_versions_present(all_builds)

	inputs = {
		"nh": os.environ.get("NH_INPUT", ""),
		"nm": os.environ.get("NM_INPUT", ""),
		"droidspaces": os.environ.get("DROIDSPACES_INPUT", ""),
		"lto": os.environ.get("LTO_INPUT", ""),
		"autofdo": os.environ.get("AUTOFDO_INPUT", ""),
		"hardening": os.environ.get("HARDENING_INPUT", ""),
		"stock_name": os.environ.get("STOCK_NAME_INPUT", ""),
		"test": os.environ.get("TEST_INPUT", ""),
	}
	status = lambda v: {"true": "Enabled", "false": "Disabled"}.get(v, "Unknown")

	warning = (
		"> [!Warning]\n> This is a test release for pipeline debugging - please do not download or install.\n\n"
		if inputs["test"] == "yes"
		else ""
	)

	toc_entries = []
	sections = []
	for kv in versions:
		builds_for_version = [b for b in all_builds if b.get("KERNEL_VERSION") == kv]
		label, section = build_kernel_section(kv, builds_for_version, repo, tag, existing_zips, inputs)
		toc_entries.append(f"- [{label}](#{slugify(label)})")
		sections.append(section)

	table_block, has_compat, has_finasu = variant_table(all_builds, inputs)
	finasu_note = (
		"**FinaSU builds** need the [FinaSU manager](https://github.com/LyraVoid/FinaSU/releases), "
		"have no KPM, and use FinaSU's own NoMount instead of the built-in one.\n\n"
		if has_finasu
		else ""
	)
	if has_compat:
		pick_advice = "**Not sure? Use a `Compat` variant first**: it fixes most boot issues."
		bootloop_advice = "Flash a **Compat** variant first."
	else:
		pick_advice = "**Pick the variant for the root manager you use**: each one needs its own manager app."
		bootloop_advice = "Flash your stock `boot.img` back from recovery or fastboot."

	toc_block = "\n".join(toc_entries)
	sections_block = "\n\n---\n\n".join(sections)

	roots = {variant_traits(b, inputs)["root"] for b in all_builds}
	has_susfs = any(b.get("KSU_SUSFS") == "true" for b in all_builds)
	lto_setting = LTO_NAMES.get(inputs["lto"], inputs["lto"] or "Unknown")

	notes = [f"- **Bootloop?** {bootloop_advice}"]
	if has_susfs:
		susfs_tools = "[ReSuSFS](https://github.com/ahmed-alnassif/ReSuSFS)"
		if has_finasu:
			susfs_tools += " or FinaSU's own SuSFS page (FinaSU builds), but not both"
		notes.append(f"- **SuSFS settings:** manage them with {susfs_tools}.")
	notes.append(f"- **Found a bug?** Check existing [Issues](https://github.com/{repo}/issues), then open one with logs.")
	notes_block = "\n".join(f"> {n}" for n in notes)

	changelog_sources = [
		("FinaSU", "FinaSU" in roots, "FinaSU_changelog.txt", "https://github.com/LyraVoid/FinaSU/commits/dev"),
		("BakaSU", "BakaSU" in roots, "BakaSU_changelog.txt", "https://github.com/Baka-SU/BakaSU/commits/main"),
		("KernelSU", "KernelSU" in roots, "ksu_changelog.txt", "https://github.com/tiann/KernelSU/commits/main"),
		# Only BakaSU/KernelSU builds carry the built-in NoMount; FinaSU loads its own
		("NoMount", inputs["nm"] == "true" and bool(roots & {"BakaSU", "KernelSU"}),
		 "nomount_changelog.txt", "https://github.com/maxsteeel/nomount/commits/master"),
	]
	changelogs = "\n\n---\n".join(
		f"""**{name} changelog (last 5 commits):**

{read_or_default(f"release-artifacts/{filename}")}

**Full commit history:** [Browse all commits]({url})"""
		for name, included, filename, url in changelog_sources
		if included
	)

	body = f"""{warning}### {release_name}

Based on [GKID Kernels](https://github.com/ahmed-alnassif/GKID-Kernels) by [Ahmed Al-Nassif](https://github.com/ahmed-alnassif). Features, install steps and credits are in the [README](https://github.com/{repo}#readme).

**Build settings:**
- LTO: {lto_setting}
- AutoFDO (6.6 and 6.12): {status(inputs['autofdo'])}
- KMI-safe hardening: {status(inputs['hardening'])}
- Kali NetHunter: {status(inputs['nh'])}
- DroidSpaces: {status(inputs['droidspaces'])}
- Built-in NoMount (not in FinaSU builds, which load their own): {status(inputs['nm'])}
- Stock-style kernel name: {status(inputs['stock_name'])}

> [!Important]
> These are **GKI** kernels, not custom kernels. Each line below supports **all** devices that shipped with the matching Linux version and Android release (stock or AOSP).

## 🧭 Which variant should I flash?

{table_block}

{finasu_note}{pick_advice} Install steps and troubleshooting are in the [README](https://github.com/{repo}#installing).

## Contents
{toc_block}

---

{sections_block}

---

> [!Note]
{notes_block}

## What's inside

- **Performance:** 300 Hz timer, MGLRU (5.15 and later), zRAM with LZ4 and writeback, schedutil and ondemand governors, mq-deadline, optimized arm64 memory routines, NTSync for Winlator and GameHub
- **Storage:** F2FS GC and fsync tuning, longer ext4 commit age
- **Battery:** 500 ms cap on userspace wakelocks, 1 s freezer timeout, fewer alarm wakeups
- **Networking:** BBRv3 (default) and Westwood+, FQ-CoDel, IP sets, IPv4/IPv6 NAT, IPsec
- **Security and hiding:** SuSFS, Baseband Guard, `/proc/config.gz` hiding, zero-width path fix

> [!Tip]
> Switch TCP congestion control until the next reboot:
> ```sh
> su -c "sysctl -w net.ipv4.tcp_congestion_control=westwood"   # Westwood+
> su -c "sysctl -w net.ipv4.tcp_congestion_control=bbr"        # BBRv3, the default
> ```
> To make it permanent, put the command in a script in `/data/adb/service.d/`.

---

{changelogs}

---
> [!Tip]
> **Checksums:**
> SHA256 checksums for all files in this release are available in [`checksums.txt`](https://github.com/{repo}/releases/download/{tag}/checksums.txt), attached below.
"""
	return body, versions, shared_env, all_builds


def export_github_env(shared_env):
	"""Expose the release tag and name to the workflow's release step."""
	github_env = os.environ.get("GITHUB_ENV")
	if not github_env:
		return

	with open(github_env, "a") as f:
		f.write(f"RELEASE={shared_env['RELEASE']}\n")
		f.write(f"RELEASE_NAME={shared_env['RELEASE_NAME']}\n")


def main():
	body, versions, shared_env, all_builds = build_release_body()
	with open("release_body.md", "w") as f:
		f.write(body)
	export_github_env(shared_env)
	print(f"[+] release_body.md written for lines: {', '.join(versions)}")


if __name__ == "__main__":
	main()
