#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). See LICENSE and NOTICE.
"""Validate project documentation, localization, and branch contract."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'arkit-3dgs-scanner'
errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


def read_strings(path):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def swift_string(source, offset):
    """Read a regular Swift literal, including balanced interpolation expressions."""
    assert source[offset] == '"'
    i = offset + 1
    pieces, arguments, part = [], 0, ''
    while i < len(source):
        if source[i] == '"':
            pieces.append(part)
            if arguments:
                pieces = [p.replace('%', '%%') for p in pieces]
            key = '%@'.join(pieces)
            # The project's UI literals use standard escaped quotes/newlines/backslashes.
            return i + 1, json.loads('"' + key + '"')
        if source.startswith('\\(', i):
            pieces.append(part)
            part = ''
            arguments += 1
            i += 2
            depth = 1
            while depth:
                if source[i] == '"':
                    i, _ = swift_string(source, i)
                    continue
                if source[i] == '(':
                    depth += 1
                elif source[i] == ')':
                    depth -= 1
                i += 1
            continue
        if source[i] == '\\':
            part += source[i:i + 2]
            i += 2
        else:
            part += source[i]
            i += 1
    raise ValueError(f'Unclosed Swift string at {offset}')


has_repository = (ROOT / '.git').exists()
branch = (subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip()
          if has_repository else '')
check(not branch or branch == 'main' or
      re.fullmatch(r'(Feature|Bugfix|Enhance)/[a-z0-9]+(?:-[a-z0-9]+)*', branch),
      f'Invalid branch name: {branch}')

check({p.name for p in APP.glob('*.lproj')} == {'en.lproj', 'zh-Hans.lproj'},
      'App must include only Simplified Chinese and English language resources')

english = read_strings(APP / 'en.lproj/Localizable.strings')
chinese = read_strings(APP / 'zh-Hans.lproj/Localizable.strings')
check(english.keys() == chinese.keys(), 'Language resource key sets differ')
placeholder = re.compile(r'%(?:\d+\$)?[-+0 #]*(?:\d+)?(?:\.\d+)?(?:ll|l)?[@difus]|%%')
for key in english.keys() | chinese.keys():
    en, zh = english.get(key, ''), chinese.get(key, '')
    check(bool(en.strip()) and bool(zh.strip()), f'Empty translation: {key}')
    check(placeholder.findall(en) == placeholder.findall(zh) == placeholder.findall(key),
          f'Format placeholder mismatch: {key}')
    check(not re.search(r'[\u3400-\u9fff]', en), f'Untranslated English resource: {key}')

used = set()
for path in APP.rglob('*.swift'):
    source = path.read_text()
    for match in re.finditer(r'L10n\.text\(\s*(?=")', source):
        _, key = swift_string(source, match.end())
        used.add(key)
        check(key in english and key in chinese, f'Missing resource in {path.name}: {key}')
check(bool(used), 'No localized messages found')
for language in ['en', 'zh-Hans']:
    permissions = read_strings(APP / f'{language}.lproj/InfoPlist.strings')
    check(bool(permissions.get('NSCameraUsageDescription')), f'Missing camera permission: {language}')

required_documents = {
    ROOT / 'README.md',
    ROOT / 'AGENTS.md',
}
module_documents = {
    ROOT / 'docs' / '采集与存储.md',
    ROOT / 'docs' / '数据处理.md',
    ROOT / 'docs' / '高斯重建.md',
    ROOT / 'docs' / '模型查看.md',
}
guide_documents = {
    ROOT / 'docs' / 'App功能与真机测试指南.md',
    ROOT / 'docs' / '数据保存格式.md',
}
for path in sorted(required_documents):
    check(path.exists(), f'缺少项目文档：{path.relative_to(ROOT)}')
    if not path.exists():
        continue
    title = re.search(r'^#\s+(.+?)\s*$', path.read_text(), flags=re.MULTILINE)
    check(title is not None and bool(re.search(r'[\u3400-\u9fff]', title.group(1))),
          f'文档需要中文标题：{path.relative_to(ROOT)}')

# 模块文档保留在完整仓库中，但最小迁移包只交接 README 和 AGENTS。
# 因此它们是可选的；存在时仍执行同一份中文与目录约束。
for path in sorted(module_documents | guide_documents):
    if not path.exists():
        continue
    title = re.search(r'^#\s+(.+?)\s*$', path.read_text(), flags=re.MULTILINE)
    check(title is not None and bool(re.search(r'[\u3400-\u9fff]', title.group(1))),
          f'文档需要中文标题：{path.relative_to(ROOT)}')

docs_markdown = set((ROOT / 'docs').rglob('*.md')) if (ROOT / 'docs').exists() else set()
extra_docs = docs_markdown - module_documents - guide_documents
for path in sorted(extra_docs):
    check(False, f'docs 目录不应包含额外 Markdown：{path.relative_to(ROOT)}')
for path in sorted(path for path in docs_markdown if path.name.endswith('.zh-TW.md')):
    check(False, f'docs 目录不应包含繁体中文副本：{path.relative_to(ROOT)}')

# Limit this to project files; a local .venv or DerivedData can contain unrelated READMEs.
if has_repository:
    project_markdown = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '*.md'],
        cwd=ROOT, text=True).split('\0')
    markdown = sorted({ROOT / name for name in project_markdown if name and (ROOT / name).exists()})
else:
    # Source transfer archives intentionally omit Git history and local dependency caches.
    markdown = sorted(set(ROOT.glob('*.md')) | set((ROOT / 'docs').rglob('*.md')))
for path in markdown:
    check(not path.name.endswith('.zh-TW.md'), f'不再维护繁体中文副本：{path.relative_to(ROOT)}')
    if path.parent == ROOT:
        check(path in required_documents, f'根目录说明应合并到 README 或 AGENTS：{path.name}')
for path in markdown:
    source = path.read_text()
    for target in re.findall(r'\]\(([^\s)]+)\)', source):
        target = target.strip('<>').split('#', 1)[0].split('?', 1)[0]
        if not target or target.startswith(('https:', 'http:', '#', 'mailto:', 'tel:', 'data:')):
            continue
        target_path = (path.parent / target).resolve()
        check(target_path.exists(), f'Broken local link in {path.relative_to(ROOT)}: {target}')

# Background 3DGS training submits continued-processing tasks; iOS refuses identifiers that
# the Info.plist does not permit, so both app configurations must use Config/Info.plist.
project = (ROOT / 'arkit-3dgs-scanner.xcodeproj' / 'project.pbxproj').read_text()
check(project.count('INFOPLIST_FILE = Config/Info.plist;') == 2,
      'The app target must use Config/Info.plist in Debug and Release')
info = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Config' / 'Info.plist')],
                                 check=True, capture_output=True, text=True).stdout)
check('$(PRODUCT_BUNDLE_IDENTIFIER).training.*' in info.get('BGTaskSchedulerPermittedIdentifiers', []),
      'Config/Info.plist must permit the 3DGS training task identifiers')
check('$(PRODUCT_BUNDLE_IDENTIFIER).reconstruction.*' in info.get('BGTaskSchedulerPermittedIdentifiers', []),
      'Config/Info.plist must permit reconstruction continued-processing identifiers')
entitlements = read_strings(ROOT / 'Config' / 'BackgroundGPU.entitlements')
check(entitlements.get('com.apple.developer.background-tasks.continued-processing.gpu') is True,
      'GPU continued processing requires its signed capability; runtime support is checked separately')

if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(used)} localized keys, {len(english)} translations per language, '
      f'{len(required_documents)} 份必需中文项目文档、'
      f'{sum(path.exists() for path in module_documents)} 份可选模块文档、'
      f'{sum(path.exists() for path in guide_documents)} 份可选使用指南；'
      f'{("branch " + (branch or "detached HEAD")) if has_repository else "源码副本（无 Git 历史）"}')
