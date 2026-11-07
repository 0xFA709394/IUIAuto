#!/usr/bin/env node
/** DSL 回归：循环作用域 / 运算符校验 / 引号定位 */
import assert from 'node:assert/strict';
import { parseScript } from './iua_dsl.js';

const loopCases = [
  ['断言属性 id=slider.demo value 等于 50', 2],
  ['断言显示 id=btn.submit', 2],
  ['页面源码', 2],
  ['元素截图 id=btn.submit a.png', 2],
  ['滚动到顶', 2],
  ['上滑 300', 2],
];
for (const [body, expected] of loopCases) {
  const steps = parseScript(`循环 2\n${body}\n结束循环`);
  assert.equal(steps.length, expected, `循环内 ${body} 应生成 ${expected} 步，实际 ${steps.length}`);
}

assert.equal(parseScript('断言值 slider.demo contains 50')[0].kind, 'value_contains');
assert.equal(parseScript('断言值 slider.demo 等于 50')[0].kind, 'value_equals');
assert.throws(() => parseScript('断言值 slider.demo 乱写 50'), /包含\/等于/);

const quoted = parseScript('点击 "xpath=//XCUIElementTypeButton[@name=\'btn.counter\']"');
assert.equal(quoted[0].params.using, 'xpath');
assert.equal(quoted[0].params.value, '//XCUIElementTypeButton[@name=\'btn.counter\']');

const quotedAssert = parseScript('断言文本 "predicate=type == \'XCUIElementTypeButton\'" 包含 点我');
assert.equal(quotedAssert[0].locator.using, '-ios predicate string');
assert.equal(quotedAssert[0].value, '点我');

console.log('DSL 回归 9/9 通过');
