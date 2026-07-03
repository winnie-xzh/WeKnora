package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"flag"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ── 数据结构 ────────────────────────────────────────────────

type FuncInfo struct {
	Name      string `json:"name"`
	Signature string `json:"signature"`
	File      string `json:"file"`
	Line      int    `json:"line"`
}

type MethodInfo struct {
	Name      string `json:"name"`
	Receiver  string `json:"receiver"`
	Signature string `json:"signature"`
	File      string `json:"file"`
	Line      int    `json:"line"`
}

type TypeInfo struct {
	Name string `json:"name"`
	Kind string `json:"kind"` // struct / interface / alias
	File string `json:"file"`
	Line int    `json:"line"`
}

type ConstVarInfo struct {
	Name string `json:"name"`
	Decl string `json:"decl"`
	File string `json:"file"`
	Line int    `json:"line"`
}

type Package struct {
	Name      string        `json:"name"`
	Dir       string        `json:"dir"`
	Files     []string      `json:"files"`
	Imports   []string      `json:"imports"`
	Doc       string        `json:"doc"`
	Functions []FuncInfo    `json:"functions"`
	Methods   []MethodInfo  `json:"methods"`
	Types     []TypeInfo    `json:"types"`
	Consts    []ConstVarInfo `json:"consts"`
	Vars      []ConstVarInfo `json:"vars"`
}

type Stats struct {
	Packages          int `json:"packages"`
	Files             int `json:"files"`
	ExportedFunctions  int `json:"exported_functions"`
	ExportedTypes     int `json:"exported_types"`
	ExportedConstsVars int `json:"exported_consts_vars"`
}

type ProjectMap struct {
	Module      string             `json:"module"`
	GeneratedAt string             `json:"generated_at"`
	Stats       Stats              `json:"stats"`
	Packages    map[string]Package `json:"packages"`
}

// ── 辅助 ────────────────────────────────────────────────────

// 从 go.mod 读取 module path
func readModulePath(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		return ""
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module "))
		}
	}
	return ""
}

// 获取导出签名的字符串表示（不含函数体）
func funcSigString(fn *ast.FuncDecl, fset *token.FileSet) string {
	// 用位置还原签名文本
	if fn.Body == nil {
		return ""
	}
	endPos := fn.Body.Pos() - 1 // 去掉 {
	start := fset.Position(fn.Pos())
	end := fset.Position(endPos)

	// 从文件读取对应行
	if start.Filename == "" || end.Filename == "" || start.Filename != end.Filename {
		return ""
	}

	data, err := os.ReadFile(start.Filename)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	if start.Line < 1 || start.Line > len(lines) || end.Line < 1 || end.Line > len(lines) {
		return ""
	}

	// 取从 start 行到 end 行的文本（同一个文件内）
	var parts []string
	for i := start.Line - 1; i < end.Line; i++ {
		parts = append(parts, lines[i])
	}
	sig := strings.Join(parts, "\n")
	// 清理尾部空格和 {
	sig = strings.TrimSpace(sig)
	sig = strings.TrimSuffix(sig, "{")
	return strings.TrimSpace(sig)
}

func typeKindString(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.StructType:
		return "struct"
	case *ast.InterfaceType:
		return "interface"
	case *ast.Ident:
		return "alias"
	case *ast.SelectorExpr:
		return "alias"
	case *ast.ArrayType:
		return "alias"
	case *ast.MapType:
		return "alias"
	case *ast.StarExpr:
		return "alias"
	default:
		_ = t
		return "alias"
	}
}

// 是否是导出名
func isExported(name string) bool {
	if name == "" {
		return false
	}
	return name[0] >= 'A' && name[0] <= 'Z'
}

// ── 分析 ────────────────────────────────────────────────────

func analyzeFile(fset *token.FileSet, f *ast.File, filename, relPath string) ([]string, []FuncInfo, []MethodInfo, []TypeInfo, []ConstVarInfo, []ConstVarInfo) {
	var imports []string
	var functions []FuncInfo
	var methods []MethodInfo
	var types []TypeInfo
	var consts []ConstVarInfo
	var vars []ConstVarInfo

	// Imports
	for _, imp := range f.Imports {
		if imp.Path != nil {
			path := strings.Trim(imp.Path.Value, "\"")
			imports = append(imports, path)
		}
	}

	// 遍历声明
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if !isExported(d.Name.Name) {
				continue
			}
			pos := fset.Position(d.Pos())
			sig := funcSigString(d, fset)
			if sig == "" {
				sig = "func " + d.Name.Name
			}
			if d.Recv != nil && len(d.Recv.List) > 0 {
				// 方法
				recv := exprString(d.Recv.List[0].Type)
				methods = append(methods, MethodInfo{
					Name:      d.Name.Name,
					Receiver:  recv,
					Signature: sig,
					File:      relPath,
					Line:      pos.Line,
				})
			} else {
				functions = append(functions, FuncInfo{
					Name:      d.Name.Name,
					Signature: sig,
					File:      relPath,
					Line:      pos.Line,
				})
			}

		case *ast.GenDecl:
			switch d.Tok {
			case token.CONST, token.VAR:
				for _, spec := range d.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok || len(vs.Names) == 0 {
						continue
					}
					for _, name := range vs.Names {
						if !isExported(name.Name) {
							continue
						}
						pos := fset.Position(name.Pos())
						decl := name.Name
						if vs.Type != nil {
							decl += " " + exprString(vs.Type)
						}
						ci := ConstVarInfo{
							Name: name.Name,
							Decl: decl,
							File: relPath,
							Line: pos.Line,
						}
						if d.Tok == token.CONST {
							consts = append(consts, ci)
						} else {
							vars = append(vars, ci)
						}
					}
				}
			case token.TYPE:
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || !isExported(ts.Name.Name) {
						continue
					}
					pos := fset.Position(ts.Pos())
					types = append(types, TypeInfo{
						Name: ts.Name.Name,
						Kind: typeKindString(ts.Type),
						File: relPath,
						Line: pos.Line,
					})
				}
			}
		}
	}

	return imports, functions, methods, types, consts, vars
}

func exprString(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.Ident:
		return e.Name
	case *ast.StarExpr:
		return "*" + exprString(e.X)
	case *ast.SelectorExpr:
		return exprString(e.X) + "." + e.Sel.Name
	case *ast.ArrayType:
		if e.Len == nil {
			return "[]" + exprString(e.Elt)
		}
		return "[" + exprString(e.Len) + "]" + exprString(e.Elt)
	case *ast.MapType:
		return "map[" + exprString(e.Key) + "]" + exprString(e.Value)
	case *ast.InterfaceType:
		return "interface{}"
	case *ast.Ellipsis:
		return "..." + exprString(e.Elt)
	case *ast.BasicLit:
		return e.Value
	case *ast.ParenExpr:
		return "(" + exprString(e.X) + ")"
	case *ast.IndexExpr:
		return exprString(e.X) + "[" + exprString(e.Index) + "]"
	case *ast.IndexListExpr:
		var args []string
		for _, arg := range e.Indices {
			args = append(args, exprString(arg))
		}
		return exprString(e.X) + "[" + strings.Join(args, ",") + "]"
	case *ast.FuncType:
		return "func(...)"
	default:
		_ = e
		return fmt.Sprintf("%T", e)
	}
}

func walkGoFiles(root string) ([]string, error) {
	var files []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		// 跳过测试文件、vendor、.git
		if info.IsDir() {
			name := info.Name()
			if name == ".git" || name == "vendor" || name == "node_modules" || name == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(info.Name(), ".go") && !strings.HasSuffix(info.Name(), "_test.go") {
			files = append(files, path)
		}
		return nil
	})
	return files, err
}

func analyzeProject(root string) (*ProjectMap, error) {
	module := readModulePath(root)
	if module == "" {
		module = "unknown"
	}

	fset := token.NewFileSet()
	pkgMap := make(map[string]*Package)
	pkgOrder := make([]string, 0)

	// 按目录分组文件
	dirFiles := make(map[string][]string)
	files, err := walkGoFiles(root)
	if err != nil {
		return nil, fmt.Errorf("walk failed: %w", err)
	}
	for _, f := range files {
		rel, err := filepath.Rel(root, filepath.Dir(f))
		if err != nil {
			continue
		}
		dirFiles[rel] = append(dirFiles[rel], f)
	}

	type importSet map[string]bool

	for dir, filePaths := range dirFiles {
		// 包路径
		var pkgPath string
		if dir == "." {
			pkgPath = module
		} else {
			pkgPath = module + "/" + dir
		}

		pkg := &Package{
				Name:      "",
				Dir:       dir,
				Files:     make([]string, 0),
				Imports:   make([]string, 0),
				Functions: make([]FuncInfo, 0),
				Methods:   make([]MethodInfo, 0),
				Types:     make([]TypeInfo, 0),
				Consts:    make([]ConstVarInfo, 0),
				Vars:      make([]ConstVarInfo, 0),
				}
		imports := make(importSet)

		for _, filePath := range filePaths {
			relFile, _ := filepath.Rel(root, filePath)

			// 用 go/parser 精确解析
			f, err := parser.ParseFile(fset, filePath, nil, parser.ParseComments)
			if err != nil {
				continue
			}

			if pkg.Name == "" {
				pkg.Name = f.Name.Name
			}

			pkg.Files = append(pkg.Files, relFile)

			// 包文档（取第一个文件的文档注释）
			if pkg.Doc == "" && f.Doc != nil {
				pkg.Doc = f.Doc.Text()
			}

			// 提取符号
			imp, funcs, meths, typs, cons, vs := analyzeFile(fset, f, filePath, relFile)

			for _, i := range imp {
				imports[i] = true
			}
			pkg.Functions = append(pkg.Functions, funcs...)
			pkg.Methods = append(pkg.Methods, meths...)
			pkg.Types = append(pkg.Types, typs...)
			pkg.Consts = append(pkg.Consts, cons...)
			pkg.Vars = append(pkg.Vars, vs...)
		}

		// 排序导入
		for i := range imports {
			pkg.Imports = append(pkg.Imports, i)
		}
		sort.Strings(pkg.Imports)

		pkgMap[pkgPath] = pkg
		pkgOrder = append(pkgOrder, pkgPath)
	}

	// 排序包
	sort.Strings(pkgOrder)
	sorted := make(map[string]Package, len(pkgOrder))
	for _, p := range pkgOrder {
		sorted[p] = *pkgMap[p]
	}

	// 统计
	var totalFiles, totalFuncs, totalTypes, totalCV int
	for _, p := range sorted {
		totalFiles += len(p.Files)
		totalFuncs += len(p.Functions) + len(p.Methods)
		totalTypes += len(p.Types)
		totalCV += len(p.Consts) + len(p.Vars)
	}

	return &ProjectMap{
		Module:      module,
		GeneratedAt: time.Now().Format(time.RFC3339),
		Stats: Stats{
			Packages:          len(sorted),
			Files:             totalFiles,
			ExportedFunctions:  totalFuncs,
			ExportedTypes:     totalTypes,
			ExportedConstsVars: totalCV,
		},
		Packages: sorted,
	}, nil
}

// ── Markdown 输出 ────────────────────────────────────────────

func toMarkdown(m *ProjectMap) string {
	var b strings.Builder

	b.WriteString(fmt.Sprintf("# %s — Project Map\n\n", m.Module))
	b.WriteString(fmt.Sprintf("_%d packages, %d files, %d exported functions, %d types, %d consts/vars_\n\n",
		m.Stats.Packages, m.Stats.Files, m.Stats.ExportedFunctions, m.Stats.ExportedTypes, m.Stats.ExportedConstsVars))

	// 按目录深度排序
	paths := make([]string, 0, len(m.Packages))
	for p := range m.Packages {
		paths = append(paths, p)
	}
	sort.Slice(paths, func(i, j int) bool {
		return paths[i] < paths[j]
	})

	for _, pkgPath := range paths {
		pkg := m.Packages[pkgPath]

		b.WriteString(fmt.Sprintf("## %s\n", pkg.Dir))
		if pkg.Doc != "" {
			firstLine := strings.SplitN(pkg.Doc, "\n", 2)[0]
			if len(firstLine) > 120 {
				firstLine = firstLine[:120] + "..."
			}
			if firstLine != "" {
				b.WriteString(fmt.Sprintf("> %s\n", firstLine))
			}
		}
		b.WriteString("\n")

		// 文件
		b.WriteString(fmt.Sprintf("Files: %d\n", len(pkg.Files)))

		// 依赖
		var internal, external []string
		for _, imp := range pkg.Imports {
			if strings.Contains(imp, m.Module) {
				internal = append(internal, imp)
			} else {
				external = append(external, imp)
			}
		}
		var parts []string
		if len(internal) > 0 {
			parts = append(parts, fmt.Sprintf("%d internal", len(internal)))
		}
		if len(external) > 0 {
			parts = append(parts, fmt.Sprintf("%d external", len(external)))
		}
		if len(parts) > 0 {
			b.WriteString(fmt.Sprintf("Imports: %s\n", strings.Join(parts, ", ")))
		}

		// 类型
		for _, t := range pkg.Types {
			b.WriteString(fmt.Sprintf("- type %s (%s)  @ %s:%d\n", t.Name, t.Kind, t.File, t.Line))
		}

		// 函数
		for _, f := range pkg.Functions {
			sig := f.Signature
			if len(sig) > 150 {
				sig = sig[:150] + "..."
			}
			// 换行替换成空格
			sig = strings.ReplaceAll(sig, "\n", " ")
			b.WriteString(fmt.Sprintf("- func %s  @ %s:%d\n", sig, f.File, f.Line))
		}

		// 方法
		for _, m := range pkg.Methods {
			sig := m.Signature
			if len(sig) > 150 {
				sig = sig[:150] + "..."
			}
			sig = strings.ReplaceAll(sig, "\n", " ")
			b.WriteString(fmt.Sprintf("- %s  @ %s:%d\n", sig, m.File, m.Line))
		}

		// 常量/变量
		for _, c := range pkg.Consts {
			b.WriteString(fmt.Sprintf("- const %s  @ %s:%d\n", c.Name, c.File, c.Line))
		}
		for _, v := range pkg.Vars {
			b.WriteString(fmt.Sprintf("- var %s  @ %s:%d\n", v.Name, v.File, v.Line))
		}

		b.WriteString("\n")
	}

	return b.String()
}

// ── 入口 ────────────────────────────────────────────────────

func main() {
	root := flag.String("root", ".", "Project root")
	output := flag.String("output", "", "Output file (default: .codex/project-map.json)")
	format := flag.String("format", "json", "Output format: json or markdown")
	printStdout := flag.Bool("print", false, "Print to stdout")
	flag.Parse()

	// 确定项目根
	projectRoot := *root
	if projectRoot == "." || projectRoot == "" {
		var err error
		projectRoot, err = os.Getwd()
		if err != nil {
			projectRoot = "/Users/winnie/WeKnora"
		}
	}

	fmt.Fprintf(os.Stderr, "Scanning project: %s\n", projectRoot)

	pm, err := analyzeProject(projectRoot)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	switch *format {
	case "markdown":
		md := toMarkdown(pm)
		if *output != "" {
			os.WriteFile(*output, []byte(md), 0644)
			fmt.Fprintf(os.Stderr, "Wrote markdown to %s\n", *output)
		}
		if *printStdout || *output == "" {
			fmt.Println(md)
		}
	default:
		data, err := json.Marshal(pm)
		if err != nil {
			fmt.Fprintf(os.Stderr, "JSON error: %v\n", err)
			os.Exit(1)
		}

		if *output == "" {
			codexDir := filepath.Join(projectRoot, ".codex")
			os.MkdirAll(codexDir, 0755)
			*output = filepath.Join(codexDir, "project-map.json")
		}
		os.WriteFile(*output, data, 0644)
		fmt.Fprintf(os.Stderr, "Wrote JSON map (%d KB) to %s\n", len(data)/1024, *output)

		// Also write pretty version
		prettyData, _ := json.MarshalIndent(pm, "", "  ")
		prettyPath := *output
		if strings.HasSuffix(prettyPath, ".json") {
			prettyPath = strings.TrimSuffix(prettyPath, ".json") + ".pretty.json"
		}
		os.WriteFile(prettyPath, prettyData, 0644)

		if *printStdout {
			fmt.Println(string(data))
		}

		s := pm.Stats
		fmt.Fprintf(os.Stderr, "Summary: %d packages, %d files, %d functions, %d types, %d consts/vars\n",
			s.Packages, s.Files, s.ExportedFunctions, s.ExportedTypes, s.ExportedConstsVars)
	}

	// 输出 JSON 路径
	enc := json.NewEncoder(os.Stdout)
	enc.Encode(map[string]string{
		"map_file": filepath.Join(projectRoot, ".codex", "project-map.json"),
	})
}
