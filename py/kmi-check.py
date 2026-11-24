#!/usr/bin/env python3
"""Compare this kernel's exported symbol CRCs with the GKI ABI (KMI).

Vendor modules on a device were built against stock GKI. A symbol whose CRC
differs means its type changed (and possibly its layout); a symbol that is
missing makes a module that needs it fail with "Unknown symbol". This build
force-loads modules despite CRC mismatches (0003-kernel-module.c patch), so
the useful question is which mismatches hit symbols vendor modules actually
use. The GKI tree lists those per vendor, and this script reports them.

Finds, in the kernel source tree:
  ABI:          android/abi_gki_aarch64.stg  (6.1, 6.6)
                gki/aarch64/abi.stg          (6.12+)
                android/abi_gki_aarch64.xml  (5.10, 5.15)
  Symbol lists: android/abi_gki_aarch64[_<vendor>] or gki/aarch64/symbols/<vendor>

Exit status: 0 = no vendor-used symbol changed or went missing,
             1 = some did, 2 = usage error or files not found.
"""

import argparse
import collections
import os
import re
import sys

ABI_CANDIDATES = (
    "android/abi_gki_aarch64.stg",
    "gki/aarch64/abi.stg",
    "android/abi_gki_aarch64.xml",
)
# Files next to the symbol lists that are not lists of symbols vendors use
NOT_SYMBOL_LISTS = {"type_visibility"}
SHOW = 25  # names printed per category in the log; the report has all of them


def parse_stg(path):
	"""elf_symbol { name: "x" ... crc: 0x... } blocks."""
	symbols, current = {}, None
	with open(path, encoding="utf-8") as f:
		for line in f:
			line = line.strip()
			if line == "elf_symbol {":
				current = {}
			elif line == "}":
				if current and "name" in current and "crc" in current:
					symbols[current["name"]] = int(current["crc"], 16)
				current = None
			elif current is not None and ":" in line:
				key, value = (part.strip() for part in line.split(":", 1))
				current[key] = value.strip('"')
	return symbols


ELF_SYMBOL_XML = re.compile(r"<elf-symbol name='([^']+)'[^>]*?\bcrc='(0x[0-9a-fA-F]+)'")


def parse_abi_xml(path):
	"""libabigail XML used by 5.10/5.15: <elf-symbol name='x' ... crc='0x...'/>."""
	symbols = {}
	with open(path, encoding="utf-8", errors="replace") as f:
		for line in f:
			m = ELF_SYMBOL_XML.search(line)
			if m:
				symbols[m.group(1)] = int(m.group(2), 16)
	return symbols


def parse_symvers(path):
	"""vmlinux.symvers: <crc> <symbol> <module> <export type> [namespace]."""
	symbols = {}
	with open(path, encoding="utf-8") as f:
		for line in f:
			fields = line.split()
			if len(fields) >= 2:
				symbols[fields[1]] = int(fields[0], 16)
	return symbols


def parse_name_list(path):
	"""Symbol list or protected exports: one name per line; skips headers and comments."""
	names = set()
	with open(path, encoding="utf-8", errors="replace") as f:
		for line in f:
			line = line.strip()
			if line and not line.startswith(("#", "[")):
				names.add(line.split()[0])
	return names


def find_symbol_lists(ksrc):
	"""{list name: set of symbols} for every vendor symbol list in the tree."""
	lists = {}
	android = os.path.join(ksrc, "android")
	if os.path.isdir(android):
		for name in os.listdir(android):
			if name == "abi_gki_aarch64":
				lists["base"] = parse_name_list(os.path.join(android, name))
			elif name.startswith("abi_gki_aarch64_") and "." not in name:
				vendor = name[len("abi_gki_aarch64_"):]
				if vendor not in NOT_SYMBOL_LISTS:
					lists[vendor] = parse_name_list(os.path.join(android, name))
	symbols_dir = os.path.join(ksrc, "gki", "aarch64", "symbols")
	if os.path.isdir(symbols_dir):
		for name in os.listdir(symbols_dir):
			if name not in NOT_SYMBOL_LISTS and os.path.isfile(os.path.join(symbols_dir, name)):
				lists[name] = parse_name_list(os.path.join(symbols_dir, name))
	return lists


def area(symbol):
	"""Rough subsystem of a symbol from its name prefix, e.g. skb_put -> skb."""
	return re.split(r"_", symbol.lstrip("_"), maxsplit=1)[0] or symbol


def top(counter, n=12):
	return ", ".join(f"{k} {v}" for k, v in counter.most_common(n))


def main():
	parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	parser.add_argument("--ksrc", required=True, help="kernel source tree")
	parser.add_argument("--symvers", required=True, help="vmlinux.symvers from the build")
	parser.add_argument("--protected-exports", help="copy of android/abi_gki_protected_exports_aarch64")
	parser.add_argument("--report", help="write the full report (every symbol) here")
	parser.add_argument("--summary-file", help="write a one-line summary here")
	args = parser.parse_args()

	abi_path = next((os.path.join(args.ksrc, c) for c in ABI_CANDIDATES
	                 if os.path.isfile(os.path.join(args.ksrc, c))), None)
	if not abi_path:
		print(f"No GKI ABI file in {args.ksrc} (looked for {', '.join(ABI_CANDIDATES)})")
		return 2
	if not os.path.isfile(args.symvers):
		print(f"{args.symvers} not found")
		return 2

	abi = parse_abi_xml(abi_path) if abi_path.endswith(".xml") else parse_stg(abi_path)
	kernel = parse_symvers(args.symvers)
	lists = find_symbol_lists(args.ksrc)
	vendor_used = set().union(*lists.values()) if lists else set()
	protected = parse_name_list(args.protected_exports) if (
		args.protected_exports and os.path.isfile(args.protected_exports)) else None

	shared = abi.keys() & kernel.keys()
	changed = sorted(s for s in shared if abi[s] != kernel[s])
	changed_set = set(changed)
	changed_used = [s for s in changed if s in vendor_used]
	missing = sorted(abi.keys() - kernel.keys())
	if protected is not None:
		missing_module = [s for s in missing if s in protected]
		missing_real = [s for s in missing if s not in protected]
	else:
		missing_module, missing_real = [], missing
	missing_used = [s for s in missing_real if s in vendor_used]

	per_list = collections.Counter({
		name: len(syms & changed_set) for name, syms in lists.items() if syms & changed_set})
	rel_abi = os.path.relpath(abi_path, args.ksrc)

	lines = [
		f"ABI: {rel_abi} ({len(abi)} symbols), kernel exports {len(kernel)}",
		f"CRC mismatches: {len(changed)} of {len(shared)} shared symbols, "
		f"{len(changed_used)} of them used by vendor modules",
	]
	if per_list:
		lines.append(f"  vendor symbol lists affected: {top(per_list)}")
	if changed:
		lines.append(f"  most affected areas: {top(collections.Counter(area(s) for s in changed))}")
	if protected is not None:
		lines.append(
			f"Missing from this kernel: {len(missing)} "
			f"({len(missing_module)} exported by Android's protected GKI modules, which this build "
			f"doesn't replace; {len(missing_real)} other, {len(missing_used)} of them used by vendor modules)")
	else:
		lines.append(
			f"Missing from this kernel: {len(missing)}, {len(missing_used)} of them used by vendor modules "
			f"(this line has no protected-exports list, so exports of Android's own GKI modules "
			f"can't be told apart and are included)")

	def section(title, names, with_crc=False):
		out = [f"{title} ({len(names)}):"]
		for s in names:
			out.append(f"  {s}  abi={abi[s]:#010x} kernel={kernel[s]:#010x}" if with_crc else f"  {s}")
		return out

	print("\n".join(lines))
	for title, names in (("Vendor-used symbols with changed CRCs", changed_used),
	                     ("Vendor-used symbols missing from this kernel", missing_used)):
		if names:
			shown = ", ".join(names[:SHOW]) + (f", ... ({len(names) - SHOW} more)" if len(names) > SHOW else "")
			print(f"{title}: {shown}")

	if args.report:
		report = lines + [""]
		report += section("Vendor-used symbols with changed CRCs", changed_used, True) + [""]
		report += section("Vendor-used symbols missing from this kernel", missing_used) + [""]
		report += section("All symbols with changed CRCs", changed, True) + [""]
		report += section("All symbols missing from this kernel", missing_real) + [""]
		if missing_module:
			report += section("Missing, exported by Android's protected GKI modules (expected)", missing_module)
		with open(args.report, "w", encoding="utf-8") as f:
			f.write("\n".join(report) + "\n")

	problem = bool(changed_used or missing_used)
	if args.summary_file:
		with open(args.summary_file, "w", encoding="utf-8") as f:
			f.write(f"{len(changed_used)} vendor-used symbols have changed CRCs "
			        f"({len(changed)} in total) and {len(missing_used)} vendor-used symbols are missing\n")
	return 1 if problem else 0


if __name__ == "__main__":
	sys.exit(main())
