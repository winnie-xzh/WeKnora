"""
农产品报价系统 Mock API 服务器
================================

模拟 Java 后端 REST API，供 MCP 网关开发调试使用。

接口清单:
  GET  /api/quotes/{product}       查询当前报价
  GET  /api/quotes/{product}/history  历史价格走势
  GET  /api/products               产品分类目录
  GET  /health                     健康检查

启动:
  python3 mock_pricing_api.py              # 默认 8080 端口
  python3 mock_pricing_api.py --port 8080  # 指定端口
"""

import argparse
import json
import math
import random
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler

# ── 模拟数据 ──────────────────────────────────────────────────────────

PRODUCTS = [
    # (名称, 分类, 基准价, 单位)
    ("大白菜", "蔬菜", 1.2, "元/斤"),
    ("西红柿", "蔬菜", 3.5, "元/斤"),
    ("黄瓜", "蔬菜", 2.8, "元/斤"),
    ("土豆", "蔬菜", 1.8, "元/斤"),
    ("青椒", "蔬菜", 4.2, "元/斤"),
    ("茄子", "蔬菜", 3.0, "元/斤"),
    ("菠菜", "蔬菜", 2.5, "元/斤"),
    ("白萝卜", "蔬菜", 1.0, "元/斤"),
    ("芹菜", "蔬菜", 2.2, "元/斤"),
    ("豆角", "蔬菜", 5.0, "元/斤"),
    ("苹果", "水果", 5.8, "元/斤"),
    ("香蕉", "水果", 3.2, "元/斤"),
    ("橙子", "水果", 4.5, "元/斤"),
    ("葡萄", "水果", 8.0, "元/斤"),
    ("草莓", "水果", 15.0, "元/斤"),
    ("西瓜", "水果", 1.5, "元/斤"),
    ("水蜜桃", "水果", 6.5, "元/斤"),
    ("梨", "水果", 3.8, "元/斤"),
    ("荔枝", "水果", 12.0, "元/斤"),
    ("猕猴桃", "水果", 7.5, "元/斤"),
    ("猪肉", "肉禽", 14.0, "元/斤"),
    ("牛肉", "肉禽", 38.0, "元/斤"),
    ("羊肉", "肉禽", 42.0, "元/斤"),
    ("鸡肉", "肉禽", 10.0, "元/斤"),
    ("鸡蛋", "肉禽", 4.5, "元/斤"),
    ("草鱼", "肉禽", 8.0, "元/斤"),
    ("鲤鱼", "肉禽", 6.5, "元/斤"),
    ("基围虾", "肉禽", 35.0, "元/斤"),
]

MARKETS = [
    "南宁海吉星", "柳州海吉星", "桂林五里店", "玉林宏进",
    "北海金癸", "梧州竹湾", "钦州东风", "百色向阳",
]

CATEGORIES = ["蔬菜", "水果", "肉禽"]


def _find_product(name: str, market: str | None = None):
    """查找产品。如果没找到返回 None。"""
    name_lower = name.strip().lower()
    for pname, cat, base, unit in PRODUCTS:
        if pname.lower() == name_lower:
            return pname, cat, base, unit
    return None


class PricingAPIHandler(BaseHTTPRequestHandler):
    """HTTP 请求处理器。"""

    def _send_json(self, data: dict, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"))

    def _send_error(self, message: str, status: int = 404):
        self._send_json({"error": message, "status": status}, status)

    def _get_market(self) -> str:
        return self._get_param("market") or random.choice(MARKETS)

    def _get_param(self, name: str) -> str | None:
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        vals = params.get(name, [])
        return vals[0] if vals else None

    def _get_page_params(self) -> tuple[int, int]:
        page = int(self._get_param("page") or 1)
        size = int(self._get_param("page_size") or 20)
        return max(1, page), min(100, max(1, size))

    # ── 路由 ──────────────────────────────────────────────────────────

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")

        if path == "/health":
            return self._send_json({"status": "ok", "service": "pricing-api"})

        if path == "/api/products":
            return self._handle_list_products()

        # GET /api/quotes/{product}/history
        if path.startswith("/api/quotes/") and path.endswith("/history"):
            product_name = path[len("/api/quotes/"):-len("/history")]
            return self._handle_price_history(product_name)

        # GET /api/quotes/{product}
        if path.startswith("/api/quotes/"):
            product_name = path[len("/api/quotes/"):]
            return self._handle_get_quote(product_name)

        self._send_error(f"Not found: {path}", 404)

    # ── 接口处理 ──────────────────────────────────────────────────────

    def _handle_get_quote(self, product_name: str):
        from urllib.parse import unquote
        name = unquote(product_name)
        found = _find_product(name)
        if not found:
            self._send_error(f"未找到农产品: {name}", 404)
            return

        pname, cat, base, unit = found
        market = self._get_market()
        date_str = self._get_param("date") or datetime.now().strftime("%Y-%m-%d")

        # 在基准价基础上加一点随机波动
        price = round(base * random.uniform(0.85, 1.15), 2)

        result = {
            "product": pname,
            "category": cat,
            "price": price,
            "unit": unit,
            "market": market,
            "date": date_str,
            "change_vs_yesterday": round(price * random.uniform(-0.05, 0.05), 2),
        }
        self._send_json({"data": result})

    def _handle_price_history(self, product_name: str):
        from urllib.parse import unquote
        name = unquote(product_name)
        found = _find_product(name)
        if not found:
            self._send_error(f"未找到农产品: {name}", 404)
            return

        pname, cat, base, unit = found
        market = self._get_market()
        days = int(self._get_param("days") or 30)
        days = min(365, max(1, days))

        today = datetime.now()
        records = []
        current_price = base
        for i in range(days - 1, -1, -1):
            date = today - timedelta(days=i)
            # 随机漫步模拟价格波动
            current_price = round(current_price * random.uniform(0.97, 1.03), 2)
            records.append({
                "date": date.strftime("%Y-%m-%d"),
                "price": current_price,
            })

        result = {
            "product": pname,
            "category": cat,
            "unit": unit,
            "market": market,
            "days": days,
            "records": records,
            "summary": {
                "highest": max(r["price"] for r in records),
                "lowest": min(r["price"] for r in records),
                "average": round(sum(r["price"] for r in records) / len(records), 2),
            },
        }
        self._send_json({"data": result})

    def _handle_list_products(self):
        category = self._get_param("category")
        page, page_size = self._get_page_params()

        filtered = PRODUCTS if not category else [p for p in PRODUCTS if p[1] == category]
        total = len(filtered)
        total_pages = math.ceil(total / page_size)
        start = (page - 1) * page_size
        end = start + page_size
        page_items = filtered[start:end]

        items = [
            {"name": p[0], "category": p[1], "unit": p[3]}
            for p in page_items
        ]

        result = {
            "items": items,
            "total": total,
            "page": page,
            "page_size": page_size,
            "total_pages": total_pages,
        }
        if category:
            result["category"] = category
        self._send_json({"data": result})

    def log_message(self, format, *args):
        """控制台日志格式。"""
        if "health" not in str(args[0]):
            print(f"[Pricing Mock] {args[0]}")


def main():
    parser = argparse.ArgumentParser(description="农产品报价 Mock API 服务器")
    parser.add_argument("--port", type=int, default=8080, help="监听端口")
    args = parser.parse_args()

    server = HTTPServer(("0.0.0.0", args.port), PricingAPIHandler)
    print(f"🍎 农产品报价 Mock API 运行中: http://localhost:{args.port}")
    print(f"   GET /health")
    print(f"   GET /api/products")
    print(f"   GET /api/quotes/{{product}}")
    print(f"   GET /api/quotes/{{product}}/history")
    print(f"   总产品数: {len(PRODUCTS)}  市场数: {len(MARKETS)}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n服务器已停止。")
        server.server_close()


if __name__ == "__main__":
    main()
