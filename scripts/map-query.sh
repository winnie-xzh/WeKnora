#!/bin/bash
# map-query.sh - 查询 WeKnora 项目符号地图
# 用法:
#   ./map-query.sh symbol <name>    - 查找符号定义
#   ./map-query.sh pkg <path>        - 查看包概览
#   ./map-query.sh search <keyword>  - 搜索符号
#   ./map-query.sh all               - 列出所有包
#   ./map-query.sh stats             - 项目统计

MAP_FILE="/private/tmp/project-map.json"

if [ ! -f "$MAP_FILE" ]; then
  echo "错误: 未找到项目地图。请先运行:"
  echo "  cd /Users/winnie/WeKnora && go run scripts/codex-map/main.go -root ."
  echo "  然后: python3 scripts/codex-map/_fix_map.py"
  exit 1
fi

case "${1:-help}" in
  symbol)
    if [ -z "$2" ]; then
      echo "用法: $0 symbol <符号名>"
      exit 1
    fi
    python3 -c "
import json
with open('$MAP_FILE') as f:
    data = json.load(f)
name = '$2'
results = []
for pkg_path, pkg in data['packages'].items():
    for f in pkg['functions']:
        if name == f['name'] or name.lower() in f['name'].lower():
            results.append(('func', f['name'], pkg['dir'], f['file'], f['line'], f.get('signature','')))
    for m in pkg['methods']:
        if name == m['name'] or name.lower() in m['name'].lower():
            results.append(('method', m['name'], pkg['dir'], m['file'], m['line'], m.get('signature','')))
    for t in pkg['types']:
        if name == t['name'] or name.lower() in t['name'].lower():
            results.append(('type', t['name'], pkg['dir'], t['file'], t['line'], t.get('kind','')))
    for c in pkg['consts']:
        if name == c['name'] or name.lower() in c['name'].lower():
            results.append(('const', c['name'], pkg['dir'], c['file'], c['line'], ''))
    for v in pkg['vars']:
        if name == v['name'] or name.lower() in v['name'].lower():
            results.append(('var', v['name'], pkg['dir'], v['file'], v['line'], ''))
if results:
    print(f'Found {len(results)} matches for "{name}":')
    print()
    for kind, sym, pkg_dir, file, line, extra in results:
        print(f'  {kind:8s} {sym}')
        print(f'            package: {pkg_dir}')
        print(f'            file:    {file}:{line}')
        if extra:
            print(f'            detail:  {extra[:120]}')
        print()
else:
    print(f'No matches found for "{name}"')
"
    ;;

  pkg)
    if [ -z "$2" ]; then
      echo "用法: $0 pkg <包路径>"
      echo "包路径示例: internal/application/service"
      echo "列出所有包: $0 all"
      exit 1
    fi
    python3 -c "
import json
with open('$MAP_FILE') as f:
    data = json.load(f)
module = data['module']
search = '$2'
# 尝试直接匹配
found = None
for pkg_path, pkg in data['packages'].items():
    if search in pkg_path or search == pkg['dir']:
        found = pkg
        break
if not found:
    for pkg_path, pkg in data['packages'].items():
        if search in pkg['dir']:
            found = pkg
            break
if found:
    print(f'Package: {found["dir"]}')
    print(f'Name:    {found["name"]}')
    print(f'Files:   {len(found["files"])}')
    if found['doc']:
        doc = found['doc'][:200]
        print(f'Doc:     {doc}')
    print()
    # 内部分依赖
    internal = [i.replace(module+'/', '') for i in found['imports'] if module in i]
    if internal:
        print(f'Internal deps ({len(internal)}):')
        for i in internal[:8]:
            print(f'  - {i}')
        if len(internal) > 8:
            print(f'  ... and {len(internal)-8} more')
    print()
    if found['types']:
        print(f'Types ({len(found["types"])}):')
        for t in found['types'][:15]:
            print(f'  {t["kind"]:10s} {t["name"]}')
        if len(found['types']) > 15:
            print(f'  ... and {len(found["types"])-15} more')
        print()
    if found['functions']:
        print(f'Functions ({len(found["functions"])}):')
        for f in found['functions'][:10]:
            sig = f.get('signature','')
            if len(sig) > 100:
                sig = sig[:100] + '...'
            print(f'  {sig}')
        if len(found['functions']) > 10:
            print(f'  ... and {len(found["functions"])-10} more')
        print()
    if found['methods']:
        print(f'Methods ({len(found["methods"])}):')
        for m in found['methods'][:10]:
            sig = m.get('signature','')
            if len(sig) > 100:
                sig = sig[:100] + '...'
            recv = m.get('receiver','')
            print(f'  {recv} -> {sig}')
        if len(found['methods']) > 10:
            print(f'  ... and {len(found["methods"])-10} more')
else:
    print(f'Package not found. Try: $0 all')
    print(f'Search term: "{search}"')
"
    ;;

  search)
    if [ -z "$2" ]; then
      echo "用法: $0 search <关键词>"
      exit 1
    fi
    python3 -c "
import json
with open('$MAP_FILE') as f:
    data = json.load(f)
kw = '$2'.lower()
results = []
for pkg_path, pkg in data['packages'].items():
    for f in pkg['functions']:
        if kw in f['name'].lower():
            results.append(('func', f['name'], pkg['dir']))
    for m in pkg['methods']:
        if kw in m['name'].lower():
            results.append(('method', m['name'], pkg['dir']))
    for t in pkg['types']:
        if kw in t['name'].lower():
            results.append(('type', t['name'], pkg['dir']))
    for c in pkg['consts']:
        if kw in c['name'].lower():
            results.append(('const', c['name'], pkg['dir']))
    for v in pkg['vars']:
        if kw in v['name'].lower():
            results.append(('var', v['name'], pkg['dir']))
results.sort(key=lambda x: x[1])
print(f'Found {len(results)} matches for "{kw}":')
print()
for kind, name, pkg_dir in results[:40]:
    print(f'  {kind:8s} {name:30s}  {pkg_dir}')
if len(results) > 40:
    print(f'  ... and {len(results)-40} more')
"
    ;;

  all)
    python3 -c "
import json
with open('$MAP_FILE') as f:
    data = json.load(f)
print(f'Packages ({data["stats"]["packages"]} total):')
print()
for pkg_path, pkg in sorted(data['packages'].items()):
    nf = len(pkg['functions'])
    nt = len(pkg['types'])
    nm = len(pkg['methods'])
    nc = len(pkg['consts']) + len(pkg['vars'])
    nd = len(pkg['files'])
    marker = ''
    if nf > 20 or nt > 20:
        marker = ' ★'
    print(f'  {pkg["dir"]:45s} {nd:3d} files  {nf:3d} funcs  {nt:3d} types  {nm:2d} methods  {nc:2d} consts{marker}')
"
    ;;

  stats)
    python3 -c "
import json, os
with open('$MAP_FILE') as f:
    data = json.load(f)
s = data['stats']
fsize = os.path.getsize('$MAP_FILE')
print(f'WeKnora 项目地图')
print(f'==============')
print(f'模块:           {data["module"]}')
print(f'生成时间:       {data["generated_at"]}')
print(f'地图文件大小:   {fsize//1024} KB ({fsize//4} tokens est)')
print(f'')
print(f'包数量:         {s["packages"]}')
print(f'源文件:         {s["files"]}')
print(f'导出函数:       {s["exported_functions"]}')
print(f'导出类型:       {s["exported_types"]}')
print(f'常量/变量:      {s["exported_consts_vars"]}')
"
    ;;

  help|*)
    echo "WeKnora 项目地图查询工具"
    echo ""
    echo "用法:"
    echo "  $(basename $0) symbol   <符号名>    查找符号定义位置"
    echo "  $(basename $0) pkg      <包路径>    查看包概览"
    echo "  $(basename $0) search   <关键词>    搜索符号"
    echo "  $(basename $0) all                  列出所有包"
    echo "  $(basename $0) stats                项目统计"
    echo ""
    echo "示例:"
    echo "  $(basename $0) symbol ChatService"
    echo "  $(basename $0) pkg handler"
    echo "  $(basename $0) search agent"
    echo "  $(basename $0) all | head -20"
    ;;
esac
