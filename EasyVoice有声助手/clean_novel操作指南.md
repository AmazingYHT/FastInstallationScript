# clean_novel.py - 小说文本清理与切分工具操作指南

## 📋 版本信息

| 版本 | 日期 | 修改内容 |
|------|------|----------|
| v1.0 | 2026-02-26 | 初始版本，支持文本清理、章节切分、有声生成 |
| v1.1 | 2026-03-04 | 功能增强：API端口修正、章节检测增强、长文本分割、重试机制 |
| v1.2 | 2026-04-08 | 渠道扩展：新增SpeechMa渠道、多线程加速、线程安全日志、25种中文语音 |

---

## 📝 v1.2 版本更新详情

### 1. 新增 SpeechMa TTS 渠道
**修改位置**: `TTS_CHANNELS` 配置 (第29-79行)

```python
TTS_CHANNELS = {
    "easyvoice": {
        "name": "EasyVoice",
        "api_url": "https://vo.zt.yonght.top:2026/api/v1/tts/generateJson",
        "max_chars": 3000,
        "voices": [...],
    },
    "speechma": {
        "name": "SpeechMa",
        "api_url": "https://speechma.com/com.api/tts-api.php",
        "max_chars": 2000,
        "voices": [
            ("voice-53", "女声-晓晓(推荐)"),
            ("voice-54", "女声-晓伊"),
            ("voice-55", "男声-云健"),
            ("voice-56", "男声-云希"),
            ("voice-57", "男声-云夏"),
            ("voice-58", "男声-云扬"),
            ("voice-59", "女声-东北话-晓北"),
            ("voice-60", "女声-陕西话-晓妮"),
            ("voice-61", "女声-粤语-晓佳"),
            ("voice-62", "女声-粤语-晓曼"),
            ("voice-63", "男声-粤语-云龙"),
            ("voice-64", "女声-台湾-晓臻"),
            ("voice-65", "女声-台湾-晓雨"),
            ("voice-66", "男声-台湾-云哲"),
            ("voice-386", "男声-美式中文-Andrew"),
            ("voice-387", "女声-美式中文-Ava"),
            ("voice-388", "男声-美式中文-Brian"),
            ("voice-389", "女声-美式中文-Emma"),
            ("voice-390", "男声-法式中文-Remy"),
            ("voice-391", "女声-法式中文-Vivienne"),
            ("voice-392", "男声-德式中文-Florian"),
            ("voice-393", "女声-德式中文-Seraphina"),
            ("voice-394", "男声-意式中文-Giuseppe"),
            ("voice-395", "男声-韩式中文-Hyunsu"),
            ("voice-396", "女声-巴西中文-Thalita"),
        ],
    }
}
```

**功能说明**:
- 支持两个 TTS 渠道切换：EasyVoice（本地/自建）和 SpeechMa（云端）
- SpeechMa 支持最多 2000 字符/请求
- EasyVoice 支持最多 3000 字符/请求
- 渠道切换时自动更新语音列表和 API 地址

---

### 2. SpeechMa 中文语音列表（25种）

| ID | 名称 | 性别 | 地区/口音 |
|---|------|------|----------|
| voice-53 | 晓晓 | 女 | 中国内地(推荐) |
| voice-54 | 晓伊 | 女 | 中国内地 |
| voice-55 | 云健 | 男 | 中国内地 |
| voice-56 | 云希 | 男 | 中国内地 |
| voice-57 | 云夏 | 男 | 中国内地 |
| voice-58 | 云扬 | 男 | 中国内地 |
| voice-59 | 晓北 | 女 | 东北话 |
| voice-60 | 晓妮 | 女 | 陕西话 |
| voice-61 | 晓佳 | 女 | 粤语(香港) |
| voice-62 | 晓曼 | 女 | 粤语(香港) |
| voice-63 | 云龙 | 男 | 粤语(香港) |
| voice-64 | 晓臻 | 女 | 台湾 |
| voice-65 | 晓雨 | 女 | 台湾 |
| voice-66 | 云哲 | 男 | 台湾 |
| voice-386 | Andrew | 男 | 美式中文 |
| voice-387 | Ava | 女 | 美式中文 |
| voice-388 | Brian | 男 | 美式中文 |
| voice-389 | Emma | 女 | 美式中文 |
| voice-390 | Remy | 男 | 法式中文 |
| voice-391 | Vivienne | 女 | 法式中文 |
| voice-392 | Florian | 男 | 德式中文 |
| voice-393 | Seraphina | 女 | 德式中文 |
| voice-394 | Giuseppe | 男 | 意式中文 |
| voice-395 | Hyunsu | 男 | 韩式中文 |
| voice-396 | Thalita | 女 | 巴西中文 |

---

### 3. SpeechMa API 调用格式
**修改位置**: `call_tts_api()` 方法

```python
if channel_key == "speechma":
    # SpeechMa 使用不同的参数格式
    rate_val = int(rate.replace('%', '').replace('+', '').replace('-', '')) if '%' in rate else 0
    pitch_val = int(pitch.replace('Hz', '').replace('+', '').replace('-', '')) if 'Hz' in pitch else 0
    
    payload = {
        "text": text,
        "voice": voice,      # 如 "voice-53"
        "pitch": pitch_val,  # 整数值
        "rate": rate_val     # 整数值
    }
else:
    # EasyVoice 格式
    payload = {
        "data": [{
            "desc": "有声小说",
            "text": text,
            "voice": voice,
            "rate": rate,
            "pitch": pitch,
            "volume": volume
        }]
    }
```

---

### 4. 多线程加速支持
**新增功能**: ThreadPoolExecutor 多线程并行处理

```python
if self.use_multithreading.get():
    worker_count = self.worker_count.get()
    self.log(f"启用多线程加速，线程数: {worker_count}")
    
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        future_to_file = {}
        for cf in chapter_files:
            future = executor.submit(
                self.process_one_chapter,
                cf, output_path, api_url, voice, rate, pitch, volume,
                channel_key, max_chars, stop_event
            )
            future_to_file[future] = cf
```

**配置选项**:
- 勾选"启用多线程"开启并行处理
- 可设置线程数（建议 2-8 个）
- 单线程模式保留暂停/继续功能

---

### 5. 线程安全日志机制
**新增方法**: `_start_log_consumer()` 和队列日志

```python
import queue

log_queue = queue.Queue()
log_file_lock = threading.Lock()

def _start_log_consumer(self):
    """在主线程消费日志队列，避免GUI跨线程问题"""
    def consume():
        try:
            while True:
                log_line = self.log_queue.get_nowait()
                self.log_text.insert(tk.END, log_line)
                self.log_text.see(tk.END)
        except queue.Empty:
            pass
        self.root.after(100, consume)
    self.root.after(100, consume)

def log(self, message):
    """线程安全的日志输出"""
    timestamp = datetime.now().strftime('%H:%M:%S')
    log_line = f"[{timestamp}] {message}\n"
    self.log_queue.put(log_line)
    # 文件写入使用锁保护
    with self.log_file_lock:
        with open(self.log_file_path, 'a', encoding='utf-8') as f:
            f.write(log_line)
```

---

### 6. 渠道切换 UI
**新增控件**: 渠道下拉选择框

```python
ttk.Label(api_frame, text="TTS渠道:").grid(row=0, column=0, sticky=tk.W, pady=3)
channel_values = [TTS_CHANNELS[k]["name"] for k in TTS_CHANNELS]
self.channel_combo = ttk.Combobox(api_frame, values=channel_values, width=15, state="readonly")
self.channel_combo.set(TTS_CHANNELS["easyvoice"]["name"])
self.channel_combo.bind("<<ComboboxSelected>>", self.on_channel_changed)

def on_channel_changed(self, event):
    """渠道切换时更新语音列表和API地址"""
    selected_name = self.channel_combo.get()
    for key, config in TTS_CHANNELS.items():
        if config["name"] == selected_name:
            self.tts_channel.set(key)
            self.api_url_entry.delete(0, tk.END)
            self.api_url_entry.insert(0, config["api_url"])
            # 更新语音下拉框
            self.voice_combo['values'] = [v[1] for v in config["voices"]]
            self.voice_combo.set(config["default_voice_desc"])
            self.voice_var.set(config["default_voice"])
            break
```

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
**修改位置**: `detect_chapter_pattern()` 方法

#### 2.1 添加调试输出
```python
lines = content.split('\n')[:20]
self.log("文件前20行（原始格式）：")
for i, line in enumerate(lines):
    self.log(f"{i+1}: {repr(line)}")
```

#### 2.2 正则模式更宽松
```diff
- (r'^第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
+ (r'^\s*第\s*[零一二三四五六七八九十百千万0-9]+\s*[章回卷节集部篇].*$', "第X章"),
```

**说明**: 添加 `\s*` 前缀，支持章节标题前有空格的情况。

---

### 3. 新增长文本分割功能
**新增方法**: `split_long_text()`

```python
def split_long_text(self, text, max_len=2500):
    """
    将长文本按段落分割成多个短文本，每段不超过 max_len 字符。
    如果段落本身超过 max_len，则按句子分割。
    """
```

**功能说明**:
- 根据渠道自动调整分割长度（EasyVoice: 3000, SpeechMa: 2000）
- 优先按段落分割
- 超长段落按句子（。！？）分割
- 分段文件自动合并为完整章节音频

---

### 4. TTS API 调用增强
**修改位置**: `call_tts_api()` 方法

#### 4.1 添加重试机制
```python
def call_tts_api(self, text, api_url, voice, rate, pitch, volume, channel_key="easyvoice", retries=3):
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

---

## 📋 功能概述

本工具是一个图形界面的小说处理工具，支持两大功能模块：

### 1. 文本清理与切分
- 清理小说文本中的多余符号和分隔符
- 按章节自动切分小说
- 自定义清理字符（特殊符号、广告词等）
- 自动检测章节标题格式

### 2. 生成有声
- **多渠道支持**: EasyVoice（本地）和 SpeechMa（云端）
- **25种中文语音**: 内地、方言、粤语、台湾、多口音
- **多线程加速**: 可选并行处理，提升效率
- 支持暂停/继续/停止控制（单线程模式）
- 长文本自动分割，避免超时
- API 请求自动重试，提高成功率

---

## 📦 环境要求

- **Python 版本**: 3.7+
- **依赖库**: requests

### 安装依赖

```bash
pip install -r requirements.txt
```

---

## 🚀 使用方法

### 启动程序

```bash
python clean_novel.py
```

---

### 功能一：文本清理与切分

#### 步骤说明

1. **选择输入文件** - 点击"浏览"选择待处理的小说txt文件

2. **选择输出目录** - 选择保存位置，默认为 `{文件名}_分章` 文件夹

3. **配置处理选项**
   - 处理模式: 清理并切分 / 仅清理
   - 文件编码: auto/utf-8/gbk/gb18030
   - 自定义清理字符

4. **开始处理** - 点击"开始处理"

---

### 功能二：生成有声

#### 步骤说明

1. **选择 TTS 渠道**
   - **EasyVoice**: 自建/本地 TTS 服务，支持 3000 字符
   - **SpeechMa**: 云端服务，支持 2000 字符，25 种中文语音

2. **选择输入源**
   - 文件夹模式: 自动处理所有txt文件
   - 多选文件模式: 手动选择指定文件

3. **配置音频输出目录**

4. **设置语音参数**
   - 语音: 根据渠道选择（切换渠道自动更新列表）
   - 语速/音调/音量: 可调节

5. **多线程设置**（可选）
   - 勾选"启用多线程"
   - 设置线程数（建议 2-8）
   - 注意：多线程模式下暂停功能不可用

6. **开始生成**
   - 点击"开始生成有声"
   - 单线程模式支持暂停/继续/停止
   - 查看日志了解进度

---

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `clean_novel.py` | 主程序 |
| `requirements.txt` | 依赖列表 |
| `docker-compose.yml` | TTS 服务 Docker 配置 |

---

## ⚠️ 注意事项

1. **渠道选择**: SpeechMa 为云端服务，无需本地部署；EasyVoice 需自建服务
2. **文件备份**: 建议先备份原始小说文件
3. **编码问题**: 乱码时尝试手动指定编码
4. **章节识别**: 章节标题需独占一行
5. **多线程**: 多线程模式下不支持暂停，单线程保留完整控制
6. **长文本**: 自动分割处理，无需手动干预

---

## 🔧 故障排查

| 问题 | 解决方案 |
|------|----------|
| 乱码 | 尝试切换文件编码，优先使用 auto |
| 无法切分 | 检查章节标题是否独占一行 |
| API调用失败 | 检查TTS服务/渠道选择，查看日志 |
| 长文本超时 | 已自动分割，无需处理 |
| SpeechMa无响应 | 检查网络连接，测试语音脚本 |
| 多线程卡住 | 降低线程数，或切换单线程模式 |