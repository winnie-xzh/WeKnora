.PHONY: proto run docker-build docker-build-push clean

# 生成 protobuf 代码
proto:
	@echo "Generating protobuf code..."
	@cd /Users/winnie/WeKnora && bash docreader/scripts/generate_proto.sh

# 运行 Python 服务（本地开发用）
run:
	@echo "Running Python server (PYTHONPATH=/Users/winnie/WeKnora)..."
	@PYTHONPATH=/Users/winnie/WeKnora uv run --directory /Users/winnie/WeKnora/docreader python -m docreader.main

docker-build:
	@echo "Building Docker image..."
	@cd /Users/winnie/WeKnora && docker build -t wechatopenai/weknora-docreader:latest -f docker/Dockerfile.docreader .

docker-build-push:
	@echo "Building and saving Docker image..."
	@cd /Users/winnie/WeKnora && docker build -t wechatopenai/weknora-docreader:latest -f docker/Dockerfile.docreader .
	@docker save wechatopenai/weknora-docreader:latest | gzip > /tmp/weknora-docreader.tar.gz
	@echo "Image saved to /tmp/weknora-docreader.tar.gz"

# 清理
clean:
	@echo "Cleaning up..."
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -delete
