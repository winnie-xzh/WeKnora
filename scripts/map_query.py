#!/usr/bin/env python3
"""WeKnora 项目地图查询工具"""

import json
import sys
import os

MAP_FILE = "/private/tmp/project-map.json"

def load_map():
    if not os.path.exists(MAP_FILE):
        print(f"Error: Map file not found at {MAP_FILE}")
        print("Generate it with:")
        print("  cd /Users/winnie/WeKnora && go run scripts/codex-map/main.go -root .")
        sys.exit(1)
    with open(MAP_FILE) as f:
        return json.load(f)

def cmd_symbol(data, name):
    results = []
    for pkg_path, pkg in data["packages"].items():
        for f in pkg["functions"]:
            if name == f["name"] or name.lower() in f["name"].lower():
                results.append(("func", f["name"], pkg["dir"], f["file"], f["line"], f.get("signature","")))
        for m in pkg["methods"]:
            if name == m["name"] or name.lower() in m["name"].lower():
                results.append(("method", m["name"], pkg["dir"], m["file"], m["line"], m.get("signature","")))
        for t in pkg["types"]:
            if name == t["name"] or name.lower() in t["name"].lower():
                results.append(("type", t["name"], pkg["dir"], t["file"], t["line"], t.get("kind","")))
        for c in pkg["consts"]:
            if name == c["name"] or name.lower() in c["name"].lower():
                results.append(("const", c["name"], pkg["dir"], c["file"], c["line"], ""))
        for v in pkg["vars"]:
            if name == v["name"] or name.lower() in v["name"].lower():
                results.append(("var", v["name"], pkg["dir"], v["file"], v["line"], ""))
    if results:
        print(f'Found {len(results)} matches for "{name}":\n')
        for kind, sym, pkg_dir, file, line, extra in results:
            print(f"  {kind:8s} {sym}")
            print(f"            package: {pkg_dir}")
            print(f"            file:    {file}:{line}")
            if extra:
                print(f"            detail:  {extra[:120]}")
            print()
    else:
        print(f'No matches found for "{name}"')

def cmd_pkg(data, search):
    module = data["module"]
    found = None
    for pkg_path, pkg in data["packages"].items():
        if search in pkg_path or search == pkg["dir"]:
            found = pkg
            break
    if not found:
        for pkg_path, pkg in data["packages"].items():
            if search in pkg["dir"]:
                found = pkg
                break
    if found:
        print(f"Package: {found['dir']}")
        print(f"Name:    {found['name']}")
        print(f"Files:   {len(found['files'])}")
        if found["doc"]:
            doc = found["doc"][:200]
            print(f"Doc:     {doc}")
        print()
        internal = [i.replace(module+"/", "") for i in found["imports"] if module in i]
        if internal:
            print(f"Internal deps ({len(internal)}):")
            for i in internal[:8]:
                print(f"  - {i}")
            if len(internal) > 8:
                print(f"  ... and {len(internal)-8} more")
        print()
        if found["types"]:
            print(f"Types ({len(found['types'])}):")
            for t in found["types"][:15]:
                print(f"  {t['kind']:10s} {t['name']}")
            if len(found["types"]) > 15:
                print(f"  ... and {len(found['types'])-15} more")
            print()
        if found["functions"]:
            print(f"Functions ({len(found['functions'])}):")
            for f in found["functions"][:10]:
                sig = f.get("signature","")
                if len(sig) > 100:
                    sig = sig[:100] + "..."
                print(f"  {sig}")
            if len(found["functions"]) > 10:
                print(f"  ... and {len(found['functions'])-10} more")
            print()
        if found["methods"]:
            print(f"Methods ({len(found['methods'])}):")
            for m in found["methods"][:10]:
                sig = m.get("signature","")
                if len(sig) > 100:
                    sig = sig[:100] + "..."
                recv = m.get("receiver","")
                print(f"  {recv} -> {sig}")
            if len(found["methods"]) > 10:
                print(f"  ... and {len(found['methods'])-10} more")
    else:
        print("Package not found.")

def cmd_search(data, keyword):
    kw = keyword.lower()
    results = []
    for pkg_path, pkg in data["packages"].items():
        for f in pkg["functions"]:
            if kw in f["name"].lower():
                results.append(("func", f["name"], pkg["dir"]))
        for m in pkg["methods"]:
            if kw in m["name"].lower():
                results.append(("method", m["name"], pkg["dir"]))
        for t in pkg["types"]:
            if kw in t["name"].lower():
                results.append(("type", t["name"], pkg["dir"]))
        for c in pkg["consts"]:
            if kw in c["name"].lower():
                results.append(("const", c["name"], pkg["dir"]))
        for v in pkg["vars"]:
            if kw in v["name"].lower():
                results.append(("var", v["name"], pkg["dir"]))
    results.sort(key=lambda x: x[1])
    print(f'Found {len(results)} matches for "{keyword}":\n')
    for kind, name, pkg_dir in results[:40]:
        print(f"  {kind:8s} {name:30s}  {pkg_dir}")
    if len(results) > 40:
        print(f"  ... and {len(results)-40} more")

def cmd_all(data):
    print(f"Packages ({data['stats']['packages']} total):\n")
    for pkg_path, pkg in sorted(data["packages"].items()):
        nf = len(pkg["functions"])
        nt = len(pkg["types"])
        nm = len(pkg["methods"])
        nc = len(pkg["consts"]) + len(pkg["vars"])
        nd = len(pkg["files"])
        marker = ""
        if nf > 20 or nt > 20:
            marker = " _"
        print(f"  {pkg['dir']:45s} {nd:3d} files  {nf:3d} funcs  {nt:3d} types  {nm:2d} methods  {nc:2d} consts{marker}")

def cmd_stats(data):
    s = data["stats"]
    fsize = os.path.getsize(MAP_FILE)
    print(f"WeKnora Project Map")
    print(f"==================")
    print(f"Module:         {data['module']}")
    print(f"Generated:      {data['generated_at']}")
    print(f"Map file:       {fsize//1024} KB ({fsize // 4} tokens est)")
    print(f"")
    print(f"Packages:       {s['packages']}")
    print(f"Source files:   {s['files']}")
    print(f"Exported funcs: {s['exported_functions']}")
    print(f"Exported types: {s['exported_types']}")
    print(f"Consts/vars:    {s['exported_consts_vars']}")

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print("WeKnora Project Map Query Tool")
        print()
        print("Usage:")
        print(f"  {sys.argv[0]} symbol <name>    Find symbol definition")
        print(f"  {sys.argv[0]} pkg <path>        Show package overview")
        print(f"  {sys.argv[0]} search <keyword>  Search symbols")
        print(f"  {sys.argv[0]} all               List all packages")
        print(f"  {sys.argv[0]} stats             Project statistics")
        print()
        print("Examples:")
        print(f"  {sys.argv[0]} symbol ChatService")
        print(f"  {sys.argv[0]} pkg handler")
        print(f"  {sys.argv[0]} search agent")
        return

    data = load_map()
    cmd = sys.argv[1]

    if cmd == "symbol":
        if len(sys.argv) < 3:
            print("Usage: map_query.py symbol <name>")
            return
        cmd_symbol(data, sys.argv[2])
    elif cmd == "pkg":
        if len(sys.argv) < 3:
            print("Usage: map_query.py pkg <path>")
            return
        cmd_pkg(data, sys.argv[2])
    elif cmd == "search":
        if len(sys.argv) < 3:
            print("Usage: map_query.py search <keyword>")
            return
        cmd_search(data, sys.argv[2])
    elif cmd == "all":
        cmd_all(data)
    elif cmd == "stats":
        cmd_stats(data)
    else:
        print(f"Unknown command: {cmd}")
        print("Use: symbol | pkg | search | all | stats")

if __name__ == "__main__":
    main()
