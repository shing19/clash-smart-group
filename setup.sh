#!/bin/bash
# Clash 智能切换组 一键配置工具
# 兼容 FlClash / ClashX Pro / Clash Verge Rev 等所有 Clash 系客户端
# 兼容 macOS / Linux / Windows (Git Bash / WSL)
# 用法: bash setup.sh

set -e

if ! command -v python3 &>/dev/null; then
    echo "❌ 需要 python3，请先安装。"
    exit 1
fi

# 写入临时文件再执行，避免 heredoc 占用 stdin 导致 input() 无法读取键盘
TMPSCRIPT="$(mktemp /tmp/clash_smart_setup.XXXXXX.py)"
trap "rm -f '$TMPSCRIPT'" EXIT

cat > "$TMPSCRIPT" << 'PYEOF'
import sys, re, os, platform, shutil
from datetime import datetime

# ══════════════════════════════════════
# 自动检测平台 & 配置文件路径
# ══════════════════════════════════════

def find_config():
    """自动检测所有已知 Clash 客户端的配置路径"""
    system = platform.system()
    home = os.path.expanduser("~")
    clients = {
        "FlClash": {
            "Darwin":  ["{home}/Library/Application Support/com.follow.clash"],
            "Linux":   ["{home}/.local/share/com.follow.clash",
                        "{home}/.config/com.follow.clash"],
            "Windows": ["{appdata}/com.follow.clash"],
        },
        "ClashX Pro": {
            "Darwin":  ["{home}/.config/clash"],
        },
        "Clash Verge Rev": {
            "Darwin":  ["{home}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"],
            "Linux":   ["{home}/.local/share/io.github.clash-verge-rev.clash-verge-rev",
                        "{home}/.config/clash-verge-rev"],
            "Windows": ["{appdata}/io.github.clash-verge-rev.clash-verge-rev"],
        },
        "Clash Verge": {
            "Darwin":  ["{home}/Library/Application Support/clash-verge"],
            "Linux":   ["{home}/.config/clash-verge"],
            "Windows": ["{appdata}/clash-verge"],
        },
        "Clash for Windows": {
            "Windows": ["{home}/.config/clash"],
            "Darwin":  ["{home}/.config/clash"],
            "Linux":   ["{home}/.config/clash"],
        },
        "mihomo (手动)": {
            "Darwin":  ["{home}/.config/mihomo"],
            "Linux":   ["{home}/.config/mihomo", "/etc/mihomo"],
            "Windows": ["{appdata}/mihomo"],
        },
    }
    appdata = os.environ.get("APPDATA", "")
    found = []
    for client_name, platforms in clients.items():
        for p in platforms.get(system, []):
            dir_path = p.format(home=home, appdata=appdata)
            config_path = os.path.join(dir_path, "config.yaml")
            if os.path.isfile(config_path):
                found.append((client_name, config_path))
    return found


# ══════════════════════════════════════
# 自动识别主选择组
# ══════════════════════════════════════

def find_main_select_group(groups_data):
    """识别被其他组引用最多的 select 组"""
    select_groups = {g["name"] for g in groups_data if g.get("type") == "select"}
    ref_count = {name: 0 for name in select_groups}
    for g in groups_data:
        for p in g.get("proxies", []):
            if p in ref_count:
                ref_count[p] += 1
    if not ref_count:
        return None
    best_name = max(ref_count, key=ref_count.get)
    for g in groups_data:
        if g["name"] == best_name:
            return g
    return None


# ══════════════════════════════════════
# 解析 proxy-groups
# ══════════════════════════════════════

def parse_proxy_groups(content):
    """从配置内容中提取 proxy-groups 段的组名和组数据"""
    pg_match = re.search(r'^proxy-groups:\s*$', content, re.MULTILINE)
    if not pg_match:
        return [], []

    pg_section = content[pg_match.end():]
    next_section = re.search(r'^\S', pg_section, re.MULTILINE)
    if next_section:
        pg_section = pg_section[:next_section.start()]

    names = re.findall(r'''name:\s*["'](.+?)["']''', pg_section)
    seen = set()
    unique = []
    for n in names:
        if n not in seen:
            seen.add(n)
            unique.append(n)

    groups_data = []
    blocks = re.split(r'\n  - ', pg_section)
    for block in blocks:
        name_m = re.search(r'''name:\s*["'](.+?)["']''', block)
        type_m = re.search(r'''type:\s*["']?(\w+)["']?''', block)
        if name_m and type_m:
            proxies = re.findall(r'''- ["'](.+?)["']''', block)
            groups_data.append({
                "name": name_m.group(1),
                "type": type_m.group(1),
                "proxies": proxies,
            })

    return unique, groups_data


# ══════════════════════════════════════
# 验证修改后的配置
# ══════════════════════════════════════

def validate_modified_config(config_path, group_name, selected, interval,
                              add_to_main, main_group_name, original_group_names):
    """
    验证修改后的配置文件是否正确。
    返回 (True, "") 或 (False, "错误原因")
    """
    errors = []

    # 1. 文件能否读取
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            new_content = f.read()
    except Exception as e:
        return False, f"无法读取修改后的文件: {e}"

    # 2. 尝试用 PyYAML 做严格验证（如果可用）
    yaml_available = False
    try:
        import yaml
        yaml_available = True
    except ImportError:
        pass

    if yaml_available:
        try:
            cfg = yaml.safe_load(new_content)
        except Exception as e:
            return False, f"YAML 语法错误: {e}"

        if not isinstance(cfg, dict):
            return False, "配置文件解析结果不是字典"

        pg = cfg.get("proxy-groups")
        if not pg or not isinstance(pg, list):
            return False, "proxy-groups 段丢失或格式错误"

        # 查找新组
        new_grp = None
        for g in pg:
            if g.get("name") == group_name:
                new_grp = g
                break

        if not new_grp:
            return False, f"新建的组「{group_name}」未找到"

        if new_grp.get("type") != "fallback":
            errors.append(f"组类型应为 fallback，实际为 {new_grp.get('type')}")

        if new_grp.get("interval") != interval:
            errors.append(f"检查间隔应为 {interval}，实际为 {new_grp.get('interval')}")

        actual_proxies = new_grp.get("proxies", [])
        if actual_proxies != selected:
            errors.append(f"成员列表不匹配: 期望 {selected}，实际 {actual_proxies}")

        # 验证新组在主选择组中
        if add_to_main:
            main_grp = None
            for g in pg:
                if g.get("name") == main_group_name:
                    main_grp = g
                    break
            if main_grp:
                if group_name not in main_grp.get("proxies", []):
                    errors.append(f"「{group_name}」未出现在「{main_group_name}」的 proxies 中")
                elif main_grp["proxies"][0] != group_name:
                    errors.append(f"「{group_name}」不在「{main_group_name}」的第一位")

        # 验证原有组没有丢失
        current_names = {g.get("name") for g in pg}
        missing = [n for n in original_group_names if n not in current_names]
        if missing:
            errors.append(f"以下原有组丢失了: {missing}")

    else:
        # 无 PyYAML，用正则做基本验证
        if "proxy-groups:" not in new_content:
            return False, "proxy-groups 段丢失"

        if f'"{group_name}"' not in new_content and f"'{group_name}'" not in new_content:
            return False, f"新建的组「{group_name}」未找到"

        for member in selected:
            if f'"{member}"' not in new_content:
                errors.append(f"成员「{member}」在配置中未找到")

        for orig in original_group_names:
            if f'"{orig}"' not in new_content and f"'{orig}'" not in new_content:
                errors.append(f"原有组「{orig}」可能丢失")

    if errors:
        return False, "; ".join(errors)

    return True, ""


# ══════════════════════════════════════
# 主流程
# ══════════════════════════════════════

print("========================================")
print("  Clash 智能切换组 配置工具")
print("========================================")
print()

# ── 1. 找配置文件 ──
found = find_config()

if not found:
    print("❌ 未找到任何 Clash 客户端的配置文件。")
    print()
    print("支持的客户端：FlClash / ClashX Pro / Clash Verge Rev / mihomo")
    print("请确认客户端已安装并至少运行过一次。")
    print()
    manual = input("手动输入 config.yaml 路径（留空退出）: ").strip()
    if not manual or not os.path.isfile(manual):
        sys.exit(1)
    found = [("手动指定", manual)]

if len(found) == 1:
    client_name, config_path = found[0]
    print(f"🔍 检测到客户端: {client_name}")
    print(f"   配置文件: {config_path}")
else:
    print("🔍 检测到多个 Clash 客户端：")
    for i, (name, path) in enumerate(found):
        print(f"  [{i+1}] {name}  ({path})")
    print()
    choice = input("👉 选择要配置的客户端编号: ").strip()
    try:
        idx = int(choice) - 1
        client_name, config_path = found[idx]
    except (ValueError, IndexError):
        print("❌ 无效选择"); sys.exit(1)

print()

# ── 2. 读取配置 ──
with open(config_path, "r", encoding="utf-8") as f:
    content = f.read()

unique_groups, groups_data = parse_proxy_groups(content)

if not unique_groups:
    print("❌ 未找到任何代理组，请检查配置文件。"); sys.exit(1)

# 记录原始组名列表（用于后续验证）
original_group_names = [g["name"] for g in groups_data]

# ── 3. 列出代理组 ──
print(f"📋 当前可用的代理组（共 {len(unique_groups)} 个）：")
print("────────────────────────────────────────")
for i, g in enumerate(unique_groups):
    print(f"  [{i+1:2d}] {g}")
print("────────────────────────────────────────")
print()
print("请输入要加入智能切换组的编号（用空格或逗号分隔，按优先级排列）")
print("例如: 1 3 5  或  1,3,5")
print()

raw = input("👉 你的选择: ").strip()
nums = raw.replace(",", " ").split()

selected = []
for n in nums:
    try:
        idx = int(n) - 1
        if 0 <= idx < len(unique_groups):
            name = unique_groups[idx]
            if name not in selected:
                selected.append(name)
        else:
            print(f"⚠️  忽略无效编号: {n}")
    except ValueError:
        print(f"⚠️  忽略无效输入: {n}")

if len(selected) < 2:
    print("❌ 至少需要选择 2 个代理组才能实现自动切换。"); sys.exit(1)

print()
print("✅ 你选择的节点（按优先级从高到低）：")
for i, s in enumerate(selected):
    print(f"   {i+1}. {s}")

# ── 4. 参数设置 ──
print()
raw_interval = input("⏱️  健康检查间隔秒数（默认 20）: ").strip()
interval = int(raw_interval) if raw_interval.isdigit() else 20

group_name = input("📝 智能切换组名称（默认：智能切换）: ").strip()
if not group_name:
    group_name = "智能切换"

# ── 5. 自动识别主选择组 ──
main_group = find_main_select_group(groups_data)
add_to_main = False
main_group_name = ""

if main_group:
    main_group_name = main_group["name"]
    print()
    print(f"🎯 检测到主选择组: 「{main_group_name}」")
    yn = input(f"   是否将「{group_name}」加入其中？(Y/n) ").strip().lower()
    add_to_main = yn != "n"
else:
    print()
    print("⚠️  未能自动识别主选择组。新组将创建但不会自动加入某个组。")
    print("   你可以稍后在客户端中手动选择。")

# ── 6. 确认 ──
print()
print("========================================")
print("  即将创建以下配置：")
print(f"  组名:     {group_name}")
print(f"  类型:     fallback（故障自动转移）")
print(f"  检查间隔: {interval}秒")
print(f"  超时判定: 5秒")
print("  成员:")
for s in selected:
    print(f"            - {s}")
if add_to_main:
    print(f"  加入到:   「{main_group_name}」（排在第一位）")
print("========================================")
print()

confirm = input("确认创建？(y/n) ").strip().lower()
if confirm != "y":
    print("已取消。"); sys.exit(0)

# ══════════════════════════════════════
# 写入流程：备份 → 修改 → 验证 → 失败回滚
# ══════════════════════════════════════

print()
print("🔧 正在修改配置...")
print()

# ── 7. 备份 ──
timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
backup_path = f"{config_path}.bak.{timestamp}"
shutil.copy2(config_path, backup_path)
print(f"  [1/4] 📦 备份完成: {backup_path}")

# ── 8. 修改配置 ──
try:
    modified = content  # 在内存中的副本上操作

    # 如果已存在同名组，先清理
    escaped = re.escape(group_name)
    if f'"{group_name}"' in modified or f"'{group_name}'" in modified:
        modified = modified.replace(f'      - "{group_name}"\n', "")
        modified = modified.replace(f"    - '{group_name}'\n", "")
        pattern = rf'  - name: "{escaped}".*?(?=\n  - )'
        modified = re.sub(pattern, "", modified, count=1, flags=re.DOTALL)

    # 构建并插入新组
    proxies_lines = "\n".join(f'      - "{m}"' for m in selected)
    new_group = (
        f'  - name: "{group_name}"\n'
        f'    type: "fallback"\n'
        f"    proxies:\n"
        f"{proxies_lines}\n"
        f'    url: "https://www.gstatic.com/generate_204"\n'
        f"    interval: {interval}\n"
        f"    lazy: false\n"
        f"    timeout: 5000\n"
    )
    modified = modified.replace("proxy-groups:\n", f"proxy-groups:\n{new_group}", 1)

    # 加入主选择组
    if add_to_main:
        escaped_main = re.escape(main_group_name)
        pat = rf'(name: "{escaped_main}"\s+proxies:\n)'
        modified = re.sub(pat, rf'\1      - "{group_name}"\n', modified, count=1)
        pat2 = rf"(name: '{escaped_main}'\s+proxies:\n)"
        modified = re.sub(pat2, rf"\1    - '{group_name}'\n", modified, count=1)

    print("  [2/4] ✏️  配置修改完成（内存中）")

except Exception as e:
    print(f"  [2/4] ❌ 修改过程出错: {e}")
    print()
    print("⚠️  配置文件未被修改，无需恢复。")
    sys.exit(1)

# ── 9. 写入文件 ──
try:
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(modified)
    print("  [3/4] 💾 写入文件完成")
except Exception as e:
    print(f"  [3/4] ❌ 写入失败: {e}")
    print()
    print("🔄 正在从备份恢复...")
    shutil.copy2(backup_path, config_path)
    print("✅ 已恢复到修改前的状态。你的配置没有受到影响。")
    sys.exit(1)

# ── 10. 自动验证 ──
print("  [4/4] 🔍 正在验证修改结果...")

ok, error_msg = validate_modified_config(
    config_path, group_name, selected, interval,
    add_to_main, main_group_name, original_group_names
)

if not ok:
    print()
    print("  ❌ 验证失败！")
    print(f"  原因: {error_msg}")
    print()
    print("🔄 正在自动恢复备份...")
    shutil.copy2(backup_path, config_path)
    print("✅ 已恢复到修改前的状态。你的配置没有受到影响。")
    print()
    print("如需反馈此问题，请提供以上错误信息。")
    sys.exit(1)

# ── 全部通过 ──
print()
print("========================================")
print("  🎉 配置成功！（已通过自动验证）")
print()
print("  接下来请：")
print("  1. 重启你的 Clash 客户端")
if add_to_main:
    print(f'  2. 在「{main_group_name}」中选择「{group_name}」')
else:
    print(f'  2. 找到「{group_name}」组并选中它')
print("  3. 开启代理即可享受自动切换")
print()
print(f'  恢复备份: cp "{backup_path}" "{config_path}"')
print("========================================")
PYEOF

python3 "$TMPSCRIPT"
