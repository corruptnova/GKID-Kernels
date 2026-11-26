#!/usr/bin/env python3
"""Show why symbols' CRCs differ from GKI's on lines using gendwarfksyms.

6.12+ GKI computes symbol CRCs from DWARF (gendwarfksyms), so the compiler's
debug info and the gendwarfksyms binary both feed into them, not just the
source. For each symbol kmi-check.py reported as changed, this prints:

  - GKI's CRC, the CRC the build recorded, and the CRC from re-running the
    build's gendwarfksyms and a gendwarfksyms built with the host's gcc on the
    same object. If the gcc-built one gives GKI's CRC, the build's gendwarfksyms
    binary is the cause, not the object's debug info.
  - The symbol's type string (gendwarfksyms --symtypes) and the strings of the
    types it names directly, to compare with a build whose CRCs match GKI's.
  - The symbol's DWARF entries (llvm-dwarfdump), to see what the compiler emitted.

Only reads the build tree; output goes to stdout (the build log). Always exits
0 so a diagnostic problem never fails the build.
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

MAX_LINE = 1500    # characters of each type string shown
MAX_DWARF = 60     # lines of llvm-dwarfdump output shown per symbol
TYPE_REF = re.compile(r"\b([sute]#[A-Za-z0-9_]+)")


def changed_symbols(report):
	"""(symbol, GKI CRC) from the 'All symbols with changed CRCs' section."""
	out, in_section = [], False
	with open(report, encoding="utf-8") as f:
		for line in f:
			if line.startswith("All symbols with changed CRCs"):
				in_section = True
			elif in_section and not line.startswith("  "):
				break
			elif in_section:
				m = re.match(r"\s+(\S+)\s+abi=(0x[0-9a-f]+)\s+kernel=(0x[0-9a-f]+)", line)
				if m:
					out.append((m.group(1), m.group(2)))
	return out


def find_objects(outdir, wanted):
	"""{symbol: (object path, CRC recorded by kbuild)} from the .<obj>.o.cmd files."""
	found = {}
	# os.walk doesn't follow symlinks (O= trees have source -> the source tree)
	for root, _, files in os.walk(outdir):
		for name in files:
			if not (name.startswith(".") and name.endswith(".o.cmd")):
				continue
			try:
				with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
					for line in f:
						if line.startswith("#SYMVER "):
							fields = line.split()
							if len(fields) >= 3 and fields[1] in wanted:
								found[fields[1]] = (os.path.join(root, name[1:-len(".cmd")]), fields[2])
			except OSError:
				pass
	return found


def tool(*names):
	return next((shutil.which(n) for n in names if shutil.which(n)), None)


def exports(obj):
	nm = tool("llvm-nm", "nm")
	res = subprocess.run([nm, obj], capture_output=True, text=True)
	return [line.split(" __export_symbol_", 1)[1] for line in res.stdout.splitlines() if " __export_symbol_" in line]


def run_gendwarfksyms(binary, obj, symtypes=None):
	"""{symbol: CRC} from running gendwarfksyms --stable on obj."""
	cmd = [binary, "--stable"] + (["--symtypes", symtypes] if symtypes else []) + [obj]
	res = subprocess.run(cmd, input="\n".join(exports(obj)) + "\n", capture_output=True, text=True)
	crcs = {}
	for line in res.stdout.splitlines():
		fields = line.split()
		if len(fields) >= 3 and fields[0] == "#SYMVER":
			crcs[fields[1]] = fields[2]
	return crcs


def build_gcc_gendwarfksyms(ksrc, workdir):
	gcc = tool("gcc")
	if not gcc:
		return None
	binary = os.path.join(workdir, "gendwarfksyms-gcc")
	srcs = sorted(glob.glob(os.path.join(ksrc, "scripts", "gendwarfksyms", "*.c")))
	res = subprocess.run([gcc, "-O2", "-I", os.path.join(ksrc, "scripts", "include")] + srcs
	                     + ["-ldw", "-lelf", "-lz", "-o", binary], capture_output=True, text=True)
	if res.returncode != 0:
		print(f"(gcc build of gendwarfksyms failed: {res.stderr.strip()[:300]})")
		return None
	return binary


def load_symtypes(path):
	types = {}
	if os.path.isfile(path):
		with open(path, encoding="utf-8", errors="replace") as f:
			for line in f:
				key, _, value = line.rstrip("\n").partition(" ")
				if key:
					types[key] = value
	return types


def clip(s, n=MAX_LINE):
	return s if len(s) <= n else s[:n] + f" ... ({len(s) - n} more characters)"


def main():
	parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	parser.add_argument("--ksrc", required=True, help="kernel source tree")
	parser.add_argument("--outdir", required=True, help="kernel build output directory (O=)")
	parser.add_argument("--report", required=True, help="report written by kmi-check.py")
	parser.add_argument("--max", type=int, default=8, help="symbols to explain (default 8)")
	args = parser.parse_args()

	build_gdk = os.path.join(args.outdir, "scripts", "gendwarfksyms", "gendwarfksyms")
	if not os.path.isfile(args.report) or not os.access(build_gdk, os.X_OK):
		print("No KMI report or gendwarfksyms binary; nothing to explain")
		return 0

	changed = changed_symbols(args.report)
	if not changed:
		print("No changed CRCs to explain")
		return 0
	if len(changed) > args.max:
		print(f"{len(changed)} changed CRCs, explaining the first {args.max}")
	changed = changed[:args.max]
	gki_crc = dict(changed)
	objects = find_objects(args.outdir, set(gki_crc))

	with tempfile.TemporaryDirectory() as workdir:
		gcc_gdk = build_gcc_gendwarfksyms(args.ksrc, workdir)
		dwarfdump = tool("llvm-dwarfdump")
		per_object = {}
		for sym, (obj, _) in objects.items():
			per_object.setdefault(obj, []).append(sym)

		for sym in gki_crc:
			if sym not in objects:
				print(f"== {sym}: GKI {gki_crc[sym]}; no object records it (assembly or generated code?)")
		for obj, syms in sorted(per_object.items()):
			rel = os.path.relpath(obj, args.outdir)
			symtypes = os.path.join(workdir, "build.symtypes")
			rerun = run_gendwarfksyms(build_gdk, obj, symtypes)
			types = load_symtypes(symtypes)
			gcc_run = run_gendwarfksyms(gcc_gdk, obj) if gcc_gdk else {}
			for sym in sorted(syms):
				print(f"== {sym} ({rel})")
				print(f"   CRC: GKI {gki_crc[sym]}, build {objects[sym][1]}, "
				      f"build's gendwarfksyms again {rerun.get(sym, '?')}, "
				      f"gcc-built gendwarfksyms {gcc_run.get(sym, '?') if gcc_gdk else 'n/a'}")
				line = types.get(sym, "")
				print(f"   type: {clip(line) if line else '(not in symtypes)'}")
				for ref in dict.fromkeys(TYPE_REF.findall(line)):
					print(f"   {ref}: {clip(types.get(ref, '(not in symtypes)'))}")
				if dwarfdump:
					res = subprocess.run([dwarfdump, f"--name={sym}", "--show-children", obj],
					                     capture_output=True, text=True)
					dies = [l for l in res.stdout.splitlines()[2:] if l.strip() and "DW_AT_decl_file" not in l]
					print(f"   DWARF ({len(dies)} lines):")
					for l in dies[:MAX_DWARF]:
						print(f"     {l.rstrip()}")
	return 0


if __name__ == "__main__":
	try:
		sys.exit(main())
	except Exception as e:  # a diagnostic must never fail the build
		print(f"kmi-explain: {e}")
		sys.exit(0)
