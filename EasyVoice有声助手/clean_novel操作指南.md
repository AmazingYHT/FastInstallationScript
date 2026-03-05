# clean_novel.py - 小说文本清理与切分工具操作指南

## 📋 版本信息

| 版本 | 日期 | 修改内容 |
|------|------|----------|
| v1.0 | 2026-02-26 | 初始版本，支持文本清理、章节切分、有声生成 |
| v1.1 | 2026-03-04 | 功能增强：API端口修正、章节检测增强、长文本分割、重试机制 |

---

## 📝 v1.1 版本更新详情

### 1. API 地址修正
**修改位置**: 第239行

```diff
- self.api_url_entry.insert(0, "http://127.0.0.1:3000/api/v1/tts/generateJson")
+ self.api_url_entry.insert(0, "http://127.0.0.1:3110/api/v1/tts/generateJson")
```

**说明**: 修正 API 默认端口为 `3110`，与 `docker-compose.yml` 中映射端口保持一致（`3110:3000`）。

---

### 2. 章节检测增强
**修改位置**: `detect_chapter_pattern()` 方法 (第484-524行)

#### 2.1 添加调试输出
```python
# 新增：输出前20行用于调试
lines = content.split('\n')[:20]
self.log("文件前20行（原始格式）：")
for i, line in enumerate(lines):
    self.log(f"{i+1}: {repr(line)}")  # repr 可以显示不可见字符
```

#### 2.2 正则模式更宽松
```diff
- (r'^第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
+ (r'^\s*第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
```

**说明**: 添加 `\s*` 前缀，支持章节标题前有空格的情况。

#### 2.3 新增终极备用模式
```python
if max_matches == 0:
    # 终极备用：只要包含"第"和"章"就认为是标题（谨慎使用）
    pattern = r'^.*第\s*[零一二三四五六七八九十百千万0-9]+\s*章.*$'
    matches = len(re.findall(pattern, content, re.MULTILINE))
    self.log(f"  终极备用模式匹配到 {matches} 个")
    if matches > 0:
        best_pattern = pattern
        best_name = "终极备用(包含'第'和'章')"
```

**说明**: 当标准模式都匹配失败时，使用更宽松的备用模式。

---

### 3. 新增长文本分割功能
**新增方法**: `split_long_text()` (第825-866行)

```python
def split_long_text(self, text, max_len=2500):
    """
    将长文本按段落分割成多个短文本，每段不超过 max_len 字符。
    如果段落本身超过 max_len，则按句子分割。
    """
```

**功能说明**:
- 每段最大 2500 字符（避免超过 TTS 服务 600 秒限制）
- 优先按段落分割
- 超长段落按句子（。！？）分割
- 自动保存为 `_part1.mp3`, `_part2.mp3` 等分段文件

---

### 4. TTS API 调用增强
**修改位置**: `call_tts_api()` 方法 (第868-943行)

#### 4.1 添加重试机制
```python
def call_tts_api(self, text, api_url, voice, rate, pitch, volume, retries=3):
    for attempt in range(1, retries + 1):
        try:
            # ... 请求逻辑
        except requests.exceptions.RequestException as e:
            if attempt < retries:
                wait = 2 ** attempt  # 指数退避：2,4,8秒...
                time.sleep(wait)
            else:
                raise Exception(f"API请求失败，已重试{retries}次: {e}")
```

#### 4.2 超时时间延长
```diff
- response = requests.post(api_url, json=payload, headers=headers, timeout=120)
+ response = requests.post(api_url, json=payload, headers=headers, timeout=300)
```

**说明**: 超时从 120 秒延长到 300 秒（5分钟），适应较长文本的生成时间。

#### 4.3 指数退避重试
| 重试次数 | 等待时间 |
|---------|---------|
| 第1次失败 | 2秒 |
| 第2次失败 | 4秒 |
| 第3次失败 | 抛出异常 |

---

### 5. 音频生成流程优化
**修改位置**: `process_audio_generation()` 方法

#### 5.1 长文本分割处理
```python
# 分割长文本（避免超过600秒限制）
text_chunks = self.split_long_text(content, max_len=2500)
if len(text_chunks) > 1:
    self.log(f"  文本较长，已分割为 {len(text_chunks)} 段")
```

#### 5.2 分段保存命名
```python
if len(text_chunks) == 1:
    audio_filename = chapter_file.stem + ".mp3"
else:
    audio_filename = f"{chapter_file.stem}_part{chunk_idx}.mp3"
```

#### 5.3 节流控制
```python
# 每段之间稍作休息
time.sleep(1)

# 每处理10个文件，休息30秒让服务恢复
if i % 10 == 0:
    self.log(f"已处理 {i} 个文件，休息30秒让服务恢复...")
    time.sleep(30)
```

---

## 📋 功能概述

本工具是一个图形界面的小说处理工具，支持两大功能模块：

### 1. 文本清理与切分
- 清理小说文本中的多余符号和分隔符
- 按章节自动切分小说
- 自定义清理字符（特殊符号、广告词等）
- 自动检测章节标题格式（v1.1 增强检测能力）

### 2. 生成有声
- 调用 TTS API 为章节生成音频
- 支持文件夹批量处理或多选文件处理
- 可调节语速、音调、音量参数
- 支持暂停/继续/停止控制
- **v1.1 新增**: 长文本自动分割，避免超时
- **v1.1 新增**: API 请求自动重试，提高成功率

## 📦 环境要求

- **Python 版本**: 3.7+
- **依赖库**: requests

### 安装依赖

```bash
pip install -r requirements.txt
```

## 🚀 使用方法

### 启动程序

```bash
python clean_novel.py
#或者直接运行
cd /d {文件目录} && python clean_novel.py
```

### 功能一：文本清理与切分

#### 步骤说明

1. **选择输入文件**
   - 点击"浏览"按钮选择待处理的小说txt文件

2. **选择输出目录**
   - 选择处理后文件的保存位置
   - 默认为源文件同目录下的 `{文件名}_分章` 文件夹

3. **配置处理选项**
   - **处理模式**: 选择"清理并按章节切分"或"仅清理文本"
   - **文件编码**: 支持 auto/utf-8/gbk/gb18030
   - **自定义清理字符**: 输入需要删除的字符，用逗号分隔

4. **快捷预设**
   - 特殊符号: ※☆★♡♥◆◇■□▲△▼▽
   - 网络表情: (笑)(哭)(怒)(汗)
   - 广告词: 本章完,求订阅,求推荐,求收藏,请关注

5. **开始处理**
   - 点击"开始处理"按钮
   - 查看日志了解处理进度

#### 支持的章节格式（v1.1 增强）

- 第X章 / 第X回 / 第X卷（支持标题前有空格）
- 数字、标题格式 (如：一、二、三、)
- Chapter X
- 序章/番外/前言/尾声等
- **新增**: 终极备用模式，更宽松的匹配

### 功能二：生成有声

#### 步骤说明

1. **选择输入源**
   - **文件夹模式**: 自动处理文件夹内所有txt文件
   - **多选文件模式**: 手动选择指定txt文件

2. **配置音频输出目录**
   - 选择音频文件的保存位置

3. **配置API**
   - API地址: `http://127.0.0.1:3110/api/v1/tts/generateJson`（v1.1 已修正）
   - 根据你的TTS服务调整地址

4. **设置语音参数**
   - **语音**: 选择中文语音模型
     - 女声: XiaoxiaoNeural、XiaoyiNeural
     - 男声: YunjianNeural、YunxiNeural、YunxiaNeural
     - 方言: 东北话、陕西话、粤语
   - **语速**: -99% ~ +99%
   - **音调**: -99Hz ~ +99Hz
   - **音量**: -99% ~ +99%

5. **开始生成**
   - 点击"开始生成有声"
   - 可随时暂停/继续/停止
   - 查看日志了解进度

#### v1.1 新特性

- **长文本自动分割**: 超过 2500 字符的章节自动分割为多段处理
- **智能重试**: API 请求失败自动重试最多 3 次，采用指数退避策略
- **服务保护**: 每处理 10 个文件自动休息 30 秒，避免服务过载

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `clean_novel.py` | 主程序 |
| `requirements.txt` | 依赖列表 (requests) |
| `docker-compose.yml` | TTS 服务 Docker 部署配置 |
| `clean_novel操作指南.md` | 本文档 |

## ⚠️ 注意事项

1. **TTS API**: 使用生成有声功能前，确保TTS API服务已启动
2. **文件备份**: 建议先备份原始小说文件
3. **编码问题**: 如果文件读取乱码，尝试手动指定编码
4. **章节识别**: 章节标题需独占一行才能正确识别
5. **长文本**: v1.1 已自动处理长文本分割，无需手动干预

## 🔧 故障排查

| 问题 | 解决方案 |
|------|----------|
| 乱码 | 尝试切换文件编码选项优先使用auto |
| 无法切分 | 检查章节标题是否独占一行，查看日志中的调试输出 |
| API调用失败 | v1.1 已自动重试，检查TTS服务是否运行，确认API地址端口为 3110 |
| 长文本超时 | v1.1 已自动分割为 2500 字符段落，无需手动处理 |
| 章节识别不准 | 查看日志中"文件前20行"输出，确认章节格式 |