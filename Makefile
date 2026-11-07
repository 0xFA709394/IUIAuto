# IUIAuto Makefile — 常用操作入口
# make setup   首次环境准备（xcodegen + npm install + 构建安装 App）
# make build   重新编译安装启动 App（改了 iOS 代码后执行）
# make gui     启动 GUI 控制台（自动开浏览器）
# make demo    CLI 全链路自动演示（12 项断言）
# make test    端到端验证：demo + 录制回放 + CLI + Appium 桥单测
# make test-appium  Appium 桥 + 模拟器真实 E2E
# make clean   清理构建产物

.PHONY: setup build gui demo test test-appium clean

setup:
	@./build.sh

build:
	@./build.sh

gui:
	@./start.sh

demo:
	@cd Tools && node mock_server.js --takeover --demo

test:
	@cd Tools && node mock_server.js --takeover --demo && node record_test.mjs && \
	 node run_script.js --takeover replay_check.txt && \
	 printf 'ping\n点击 btn.counter\n断言存在 btn.counter\n' > /tmp/mk_check.txt && \
	 node run_script.js --takeover /tmp/mk_check.txt && node appium_bridge_test.mjs

test-appium:
	@cd Tools && node appium_bridge_test.mjs && node appium_e2e_test.mjs

clean:
	@rm -rf ~/Library/Developer/Xcode/DerivedData/IUIAuto-* Tools/shot.png Tools/fail.png
	@echo "已清理构建产物"
